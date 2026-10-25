-- scenarios/dataTypes.lua
-- Writes values of many types through prepared statements into a test
-- table, reads them back and compares. Checks correctness at type
-- boundaries, not leaks; every case runs once, independent of the tier.
--
-- Blocks, in this order:
--   numbers, dates, booleans  once per test locale of the backend
--                             (decimal comma, date format); the session
--                             locale must not change any result; dates
--                             include intervals
--   numbers, float mode       again with conn:setoption("numbers",
--                             "float"), if the driver has it
--   strings                   multibyte, length limit, empty, \0,
--                             national character set, fixed length
--   rowids                    ROWIDs read as strings must find their
--                             row again, also logical ROWIDs and
--                             ROWIDs stored in a column
--   raw                       binary data, written as hex text, read
--                             as bytes; also checked as hex on the
--                             server
--   clob, blob, json          last: a failed LOB read may leave the
--                             session unusable; the driver reads JSON
--                             through a CLOB
--   rows                      several rows in one cursor: changing
--                             lengths, NULL between values, several
--                             columns at once
--   unsupported               column types the driver does not support
--                             on purpose: reading must fail cleanly; a
--                             known limitation
--
-- Cases with TIMESTAMP WITH LOCAL TIME ZONE also read the value as text
-- on the server (TO_CHAR in the same session) and run in several session
-- time zones: one that differs from the offset of this computer, and a
-- region with summer and winter time. A client library that converts
-- in its own time zone instead of the session's fails there.
--
-- Every read also checks the column type the driver reports
-- (cur:getcoltypes()) against backend.columnTypes, if given.
--
-- Number cases also read the stored value as text on the server and
-- convert it with tonumber. That tells whether a wrong result was lost
-- while binding or while reading. In exact mode a number must also have
-- the expected subtype (integer or float); in float mode every number
-- must be a float close to the expected value. Binary floating point
-- columns (BINARY_FLOAT, BINARY_DOUBLE) hold IEEE values that the client
-- library does not convert: their cases must be exact in every mode and
-- skip the server text check.
--
-- A case that hits a documented limit of the DBMS or its client library
-- counts as "limit", not as failure: it is listed with its reason, but
-- does not fail the scenario. The reasons come from backend.limits and
-- the case overrides, so they can go into the documentation.
--
-- Some cases read with fetch modes other than fetch({}): "a" (named
-- keys), "na" (both, every column is read twice) and "multi" (fetch()
-- without a table, values as return values).
--
-- Skipped if the driver has no prepare() or the backend has no test
-- table.

local dbutil = require("dbutil")
local report = require("report")

local dataTypes = {}

-- Session time zone during the run; the cases with time zone expect
-- this offset.
local testTimeZone = "+02:00"

-- Session time zone for a case that must not match the offset of this
-- computer: the first of these that differs from os.date("%z").
local foreignTimeZones = { "+05:45", "-03:30" }

-- Region with summer and winter time for the LTZ cases.
local regionTimeZone = "Europe/Berlin"

-- First of foreignTimeZones that differs from the offset of this
-- computer ("+0100" from os.date("%z") is compared as "+01:00").
local function foreignTimeZone()
   local own = os.date("%z")
   own = own:gsub("^([+-]%d%d)(%d%d)$", "%1:%2")
   for _, zone in ipairs(foreignTimeZones) do
      if zone ~= own then
         return zone
      end
   end
end

-- 2026-10-19 11:45:30 UTC as local time in zone ("+hh:mm" or
-- "-hh:mm"); the zones above keep the date.
local function timeInZone(zone)
   local sign, hours, minutes = zone:match("^([+-])(%d%d):(%d%d)$")
   local shift = tonumber(hours) * 60 + tonumber(minutes)
   if sign == "-" then
      shift = -shift
   end
   local total = 11 * 60 + 45 + shift
   return string.format("2026-10-19 %02d:%02d:30.000000", total // 60,
                        total % 60)
end

-- Numbers read in float mode are converted by OCI, which is off by a
-- few ULP (about 4e-16 relative was seen); allowed relative deviation.
local floatModeTolerance = 1e-14

-- a-umlaut, o-umlaut, u-umlaut (2 bytes each), euro sign (3 bytes) and
-- an emoji (4 bytes).
local utf8Text = "\u{E4}\u{F6}\u{FC}\u{20AC}\u{1F600}"

-- Exactly 4000 bytes: 1333 euro signs of 3 bytes plus one ASCII byte.
local maxBytesText = string.rep("\u{20AC}", 1333) .. "x"

local asciiClob = string.rep("abc", 1000)
local utf8Clob = string.rep(utf8Text, 100)
-- 65000 bytes, far above the 4000 byte limit of string binds in SQL.
local largeClob = string.rep(utf8Text, 5000)
local zeroClob = "ab\0cd" .. asciiClob

-- Builds the case list. A case has: name, block, column, param (as for
-- stmt:execute) and expected; optional: nullResult (expect NULL),
-- expectError, errorAllowed (an error is fine, a wrong value is not),
-- needsTimeZone, checkServer (also check the value stored on the
-- server), literal (SQL literal written instead of param), fetchMode
-- ("a", "na" or "multi"), exactRead (exact in float mode, too),
-- needs (backend keys the case needs), rowid (ROWID case, see
-- runRowidCase; with iot and store), checkHex (also check the bytes
-- stored on the server; set for all raw cases), expectedLength (value
-- made on the server: expect the stored bytes of this length), write
-- (backend key of a statement that writes row :1, with writeParams; %s
-- is the column), checkText (backend key of an expression that gives
-- the text of the value on the server; %s is the column), readExpression
-- (read instead of the column), columnType (expected column type, for a
-- readExpression), unsupported (key in backend.unsupportedTypes),
-- columns and rows (rows case, see runRowsCase), sessionTimeZone (the
-- case runs with this session time zone instead of testTimeZone).
-- Backend overrides may add limitReason with limitNull (NULL read back)
-- or limitError (Lua pattern of an expected write error).
local function makeCases(t)
   local list = {}
   local function add(name, block, column, param, expected, extra)
      local case = { name = name, block = block, column = column,
                     param = param, expected = expected }
      -- Finite numbers only: infinity has no exact text form.
      if block == "numbers" and type(expected) == "number"
         and math.abs(expected) ~= math.huge then
         case.checkServer = true
      end
      if block == "raw" then
         case.checkHex = true
      end
      for key, value in pairs(extra or {}) do
         case[key] = value
      end
      list[#list + 1] = case
   end
   local null = { nullResult = true }
   local fails = { expectError = true }
   -- Binary floating point: no server text check, exact in every mode.
   local function native(extra)
      extra = extra or {}
      extra.checkServer = false
      extra.exactRead = true
      return extra
   end

   add("intSmall", "numbers", "n", { 42, t.int }, 42)
   add("intNegative", "numbers", "n", { -7, t.int }, -7)
   add("intAsNumber", "numbers", "n", { 42, t.number }, 42)
   add("int2pow53", "numbers", "n",
       { 9007199254740992, t.int }, 9007199254740992)
   add("int2pow53plus1", "numbers", "n",
       { 9007199254740993, t.int }, 9007199254740993)
   add("intMax", "numbers", "n",
       { math.maxinteger, t.int }, math.maxinteger)
   add("intMin", "numbers", "n",
       { math.mininteger, t.int }, math.mininteger)
   -- Integral, but outside the integer range: must come back as float.
   add("int2pow63", "numbers", "n", { 2.0 ^ 63, t.number }, 2.0 ^ 63)
   add("int1e20", "numbers", "n", { 1e20, t.number }, 1e20)
   add("intMinus1e19", "numbers", "n", { -1e19, t.number }, -1e19)
   add("float", "numbers", "n", { 0.1, t.number }, 0.1)
   add("floatNegative", "numbers", "n", { -123.456, t.number }, -123.456)
   add("floatTiny", "numbers", "n", { 1e-100, t.number }, 1e-100)
   add("floatHuge", "numbers", "n", { 1.5e100, t.number }, 1.5e100)
   -- 16 and 17 significant digits, as in everyday calculations.
   add("floatPi", "numbers", "n", { math.pi, t.number }, math.pi)
   add("floatSum", "numbers", "n", { 0.1 + 0.2, t.number }, 0.1 + 0.2)
   add("floatOverflow", "numbers", "n", { 1e200, t.number }, nil, fails)
   add("infinity", "numbers", "n", { math.huge, t.number }, math.huge,
       { errorAllowed = true })
   add("infinityNeg", "numbers", "n", { -math.huge, t.number }, -math.huge,
       { errorAllowed = true })
   add("numberNull", "numbers", "n", t.null, nil, null)
   add("intFetchNa", "numbers", "n", { 42, t.int }, 42,
       { fetchMode = "na" })
   add("floatFetchMulti", "numbers", "n", { 0.25, t.number }, 0.25,
       { fetchMode = "multi" })
   -- Written as SQL literals, so the read path for 16 and 17 digits is
   -- not hidden by the bind limit; the expected values are hex float
   -- literals, which Lua parses exactly.
   add("litPi", "numbers", "n", nil, 0x1.921fb54442d18p+1,
       { literal = "3.141592653589793" })
   add("litSum", "numbers", "n", nil, 0x1.3333333333334p-2,
       { literal = "0.30000000000000004" })
   add("litE", "numbers", "n", nil, -0x1.5bf0a8b145769p+1,
       { literal = "-2.718281828459045" })
   -- 40 digits on the server.
   add("litThird", "numbers", "n", nil, 0x1.5555555555555p-2,
       { literal = "1/3" })
   -- Largest and smallest NUMBER, read in scientific notation.
   add("litMax", "numbers", "n", nil, 0x1.7a2ecc414a03fp+418,
       { literal = "9.999999999999999999999999999999999999999E125" })
   add("litTiny", "numbers", "n", nil, 0x1.1bebdf578b2f4p-432,
       { literal = "1E-130" })
   add("nanNumber", "numbers", "n", { 0 / 0, t.number }, 0 / 0,
       { checkServer = false })
   -- 0.1 rounded to single precision, as BINARY_FLOAT stores it.
   local float32 = string.unpack("f", string.pack("f", 0.1))
   add("bfloat", "numbers", "bf", nil, float32, native({ literal = "0.1f" }))
   add("bfloatBind", "numbers", "bf", { 0.1, t.number }, float32, native())
   add("bfloatInf", "numbers", "bf", nil, math.huge,
       native({ literal = "BINARY_FLOAT_INFINITY" }))
   add("bdouble", "numbers", "bd", nil, 0.1 + 0.2,
       native({ literal = "0.1d + 0.2d" }))
   add("bdoubleHuge", "numbers", "bd", nil, 1e300,
       native({ literal = "1e300d" }))
   add("bdoubleInf", "numbers", "bd", nil, -math.huge,
       native({ literal = "-BINARY_DOUBLE_INFINITY" }))
   add("bdoubleNan", "numbers", "bd", nil, 0 / 0,
       native({ literal = "BINARY_DOUBLE_NAN" }))
   add("bdoubleBind", "numbers", "bd", { 0.1 + 0.2, t.number }, 0.1 + 0.2,
       native())
   add("bdoubleInfBind", "numbers", "bd", { math.huge, t.number },
       math.huge, native())
   add("bdoubleNegInfBind", "numbers", "bd", { -math.huge, t.number },
       -math.huge, native())
   add("bdoubleNanBind", "numbers", "bd", { 0 / 0, t.number }, 0 / 0,
       native())
   add("bdoubleNull", "numbers", "bd", t.null, nil,
       native({ nullResult = true }))

   add("date", "dates", "d", { "2026-10-19", t.date },
       "2026-10-19 00:00:00")
   add("leapDay", "dates", "d", { "2024-02-29", t.date },
       "2024-02-29 00:00:00")
   add("invalidDate", "dates", "d", { "2026-02-30", t.date }, nil, fails)
   add("dateWithTime", "dates", "d",
       { "2026-10-19 13:45:30", t.timestamp }, "2026-10-19 13:45:30")
   add("timestamp", "dates", "ts",
       { "2026-10-19 13:45:30", t.timestamp },
       "2026-10-19 13:45:30.000000")
   -- Binds have no fractional seconds, so a literal is written instead.
   add("timestampFraction", "dates", "ts", nil,
       "2026-10-19 13:45:30.123456",
       { literal = "TIMESTAMP '2026-10-19 13:45:30.123456'" })
   add("timestampTz", "dates", "tstz",
       { "2026-10-19 13:45:30", t.timestamp },
       "2026-10-19 13:45:30.000000 " .. testTimeZone,
       { needsTimeZone = true })
   add("timestampTzOffset", "dates", "tstz", nil,
       "2026-10-19 13:45:30.500000 +05:30",
       { literal = "TIMESTAMP '2026-10-19 13:45:30.5 +05:30'" })
   -- LTZ values come in the session time zone; checked against TO_CHAR
   -- in the same session.
   local function ltz(extra)
      extra.needsTimeZone = true
      extra.checkText = "timestampAsText"
      return extra
   end
   add("timestampLtz", "dates", "tsltz",
       { "2026-10-19 13:45:30", t.timestamp },
       "2026-10-19 13:45:30.000000", ltz({}))
   local foreign = foreignTimeZone()
   add("ltzOtherZone", "dates", "tsltz", nil, timeInZone(foreign),
       ltz({ literal = "TIMESTAMP '2026-10-19 13:45:30 +02:00'",
             sessionTimeZone = foreign }))
   add("ltzSummer", "dates", "tsltz", nil, "2026-07-15 14:00:00.000000",
       ltz({ literal = "TIMESTAMP '2026-07-15 12:00:00 UTC'",
             sessionTimeZone = regionTimeZone }))
   add("ltzWinter", "dates", "tsltz", nil, "2026-01-15 13:00:00.000000",
       ltz({ literal = "TIMESTAMP '2026-01-15 12:00:00 UTC'",
             sessionTimeZone = regionTimeZone }))
   add("dateNull", "dates", "d", t.null, nil, null)
   -- Bind formats: DATE with optional time, TIMESTAMP with optional
   -- fraction; years before Christ with a minus sign.
   add("dateBindTime", "dates", "d", { "2026-10-19 13:45:30", t.date },
       "2026-10-19 13:45:30")
   add("dateBindFraction", "dates", "d",
       { "2026-10-19 13:45:30.5", t.date }, nil, fails)
   add("tsBindFraction", "dates", "ts",
       { "2026-10-19 13:45:30.123456", t.timestamp },
       "2026-10-19 13:45:30.123456")
   add("tsBindZone", "dates", "tstz",
       { "2026-10-19 13:45:30 +02:00", t.timestamp }, nil,
       { needsTimeZone = true })
   add("dateMin", "dates", "d", { "0001-01-01", t.date },
       "0001-01-01 00:00:00")
   add("dateMax", "dates", "d", { "9999-12-31 23:59:59", t.date },
       "9999-12-31 23:59:59")
   add("dateOld", "dates", "d", { "1900-03-01", t.date },
       "1900-03-01 00:00:00")
   add("dateBc", "dates", "d", { "-4712-01-01", t.date },
       "-4712-01-01 00:00:00")
   add("dateBcLiteral", "dates", "d", nil, "-0044-03-15 00:00:00",
       { literal = "DATE '-0044-03-15'" })
   add("tsBc", "dates", "ts", { "-0044-03-15 12:00:00.25", t.timestamp },
       "-0044-03-15 12:00:00.250000")
   add("tsMax", "dates", "ts",
       { "9999-12-31 23:59:59.999999", t.timestamp },
       "9999-12-31 23:59:59.999999")
   add("tstzBcLiteral", "dates", "tstz", nil,
       "-0044-03-15 12:00:00.000000 +01:00",
       { literal = "TIMESTAMP '-0044-03-15 12:00:00 +01:00'" })
   -- luasql.type.time is bound as a plain string.
   add("timeAsString", "dates", "s", { "13:45:30", t.time }, "13:45:30")
   add("timeInDate", "dates", "d", { "13:45:30", t.time }, nil)

   -- Intervals, read as Oracle's text form in the precision of the
   -- column and compared with the text of the server. Binds are strings
   -- converted on the server.
   local function interval(extra)
      extra = extra or {}
      extra.checkText = "intervalAsText"
      return extra
   end
   local function ymBind(text)
      return interval({ write = "ymIntervalInsert",
                        writeParams = { { text, t.string } } })
   end
   local function dsBind(text)
      return interval({ write = "dsIntervalInsert",
                        writeParams = { { text, t.string } } })
   end
   add("ymLiteral", "dates", "iym", nil, "+01-02",
       interval({ literal = "INTERVAL '1-2' YEAR TO MONTH" }))
   add("ymBind", "dates", "iym", nil, "+01-02", ymBind("1-2"))
   add("ymNegative", "dates", "iym", nil, "-01-02", ymBind("-1-2"))
   -- The text the driver reads must be accepted as input again.
   add("ymOwnText", "dates", "iym", nil, "+01-02", ymBind("+01-02"))
   add("ymYear4", "dates", "iym4", nil, "+0001-02", ymBind("1-2"))
   add("ymNull", "dates", "iym", t.null, nil, interval({ nullResult = true }))
   add("dsLiteral", "dates", "ids", nil, "+01 02:03:04.500000",
       interval({ literal = "INTERVAL '1 2:3:4.5' DAY TO SECOND" }))
   add("dsBind", "dates", "ids", nil, "+01 02:03:04.500000",
       dsBind("1 02:03:04.5"))
   add("dsNegative", "dates", "ids", nil, "-01 02:03:04.500000",
       dsBind("-1 02:03:04.5"))
   add("dsOwnText", "dates", "ids", nil, "+01 01:29:44.750000",
       dsBind("+000000001 01:29:44.750000000"))
   add("dsDay3", "dates", "ids3", nil, "+123 02:03:04.56",
       dsBind("123 2:3:4.56"))
   local tooLarge = dsBind("123 0:0:0")
   tooLarge.expectError = true
   add("dsTooLarge", "dates", "ids", nil, nil, tooLarge)
   -- A computed interval has the largest precisions (9 and 9).
   add("dsDifference", "dates", "ts", nil, "+000000001 01:29:44.750000000",
       interval({ literal = "TIMESTAMP '2026-10-20 13:45:44.75'",
                  readExpression = "ts - TIMESTAMP '2026-10-19 12:16:00'" }))
   add("dsFetchNa", "dates", "ids", nil, "+01 02:03:04.500000",
       interval({ literal = "INTERVAL '1 2:3:4.5' DAY TO SECOND",
                  fetchMode = "na" }))
   add("dsNull", "dates", "ids", t.null, nil, interval({ nullResult = true }))

   add("trueAsNumber", "booleans", "n", { true, t.boolean }, 1)
   add("falseAsNumber", "booleans", "n", { false, t.boolean }, 0)
   add("booleanColumn", "booleans", "b", { true, t.boolean }, true)
   add("booleanFalse", "booleans", "b", { false, t.boolean }, false)
   add("booleanNull", "booleans", "b", t.null, nil, null)
   add("booleanFetchNa", "booleans", "b", { true, t.boolean }, true,
       { fetchMode = "na" })

   add("ascii", "strings", "s", { "hello", t.string }, "hello")
   add("utf8", "strings", "s", { utf8Text, t.string }, utf8Text)
   add("spaces", "strings", "s", { "  padded  ", t.string }, "  padded  ")
   add("maxBytes", "strings", "s", { maxBytesText, t.string },
       maxBytesText)
   add("tooLong", "strings", "s", { maxBytesText .. "x", t.string }, nil,
       fails)
   add("emptyString", "strings", "s", { "", t.string }, "")
   add("embeddedZero", "strings", "s", { "ab\0cd", t.string }, "ab\0cd")
   add("stringNull", "strings", "s", t.null, nil, null)
   add("stringFetchA", "strings", "s", { utf8Text, t.string }, utf8Text,
       { fetchMode = "a" })
   add("stringFetchMulti", "strings", "s", { utf8Text, t.string },
       utf8Text, { fetchMode = "multi" })
   add("nvarchar", "strings", "ns", { utf8Text, t.string }, utf8Text)
   add("nvarcharLong", "strings", "ns", { maxBytesText, t.string },
       maxBytesText)
   add("nvarcharNull", "strings", "ns", t.null, nil, null)
   -- Fixed length columns of 10 characters, padded with spaces.
   add("charPadded", "strings", "ch", { "abc", t.string },
       "abc" .. string.rep(" ", 7))
   add("charFull", "strings", "ch", { string.rep("\u{20AC}", 10), t.string },
       string.rep("\u{20AC}", 10))
   add("charTooLong", "strings", "ch", { "abcdefghijk", t.string }, nil,
       fails)
   add("charEmpty", "strings", "ch", { "", t.string },
       string.rep(" ", 10))
   add("charNull", "strings", "ch", t.null, nil, null)
   -- 10 euro signs: 20 bytes in AL16UTF16, 30 bytes in UTF-8.
   add("ncharEuro", "strings", "nch",
       { string.rep("\u{20AC}", 10), t.string },
       string.rep("\u{20AC}", 10))
   -- 5 emojis: 2 UTF-16 code units each, so the column is full.
   add("ncharEmoji", "strings", "nch",
       { string.rep("\u{1F600}", 5), t.string },
       string.rep("\u{1F600}", 5))
   add("ncharPadded", "strings", "nch", { "\u{E4}", t.string },
       "\u{E4}" .. string.rep(" ", 9))
   add("ncharNull", "strings", "nch", t.null, nil, null)

   local rowidNeeds = { "rowidSelect", "rowidLookup" }
   local iotNeeds = { "rowidSelect", "rowidLookup", "iotTableCreate" }
   add("rowid", "rowids", nil, nil, nil,
       { rowid = true, needs = rowidNeeds })
   add("rowidLogical", "rowids", nil, nil, nil,
       { rowid = true, iot = true, needs = iotNeeds })
   add("urowid", "rowids", "r", nil, nil,
       { rowid = true, store = true, needs = rowidNeeds })
   add("urowidLogical", "rowids", "r", nil, nil,
       { rowid = true, iot = true, store = true, needs = iotNeeds })
   add("urowidNull", "rowids", "r", t.null, nil, null)

   -- RAW: string binds and literals are hex text, reads give the bytes.
   local bytes = "\0\255A\0"
   add("rawLiteral", "raw", "rw", nil, bytes,
       { literal = "HEXTORAW('00FF4100')" })
   add("rawHexBind", "raw", "rw", { "00FF4100", t.string }, bytes)
   add("rawHexLower", "raw", "rw", { "deadbeef", t.string },
       "\xDE\xAD\xBE\xEF")
   add("rawLarge", "raw", "rw", nil, string.rep("\xDE\xAD\xBE\xEF", 500),
       { literal = "UTL_RAW.COPIES(HEXTORAW('DEADBEEF'), 500)" })
   add("rawGuid", "raw", "rw", nil, nil,
       { literal = "SYS_GUID()", expectedLength = 16,
         needs = { "rawAsHex" } })
   add("rawTooLong", "raw", "rw", { string.rep("AB", 2001), t.string },
       nil, fails)
   add("rawInvalidHex", "raw", "rw", { "XYZ", t.string }, nil, fails)
   add("rawEmpty", "raw", "rw", { "", t.string }, "")
   add("rawNull", "raw", "rw", t.null, nil, null)
   add("rawFetchNa", "raw", "rw", { "00FF4100", t.string }, bytes,
       { fetchMode = "na" })

   -- BLOB: written as hex text or RAW, read as bytes.
   add("blobLiteral", "blob", "bl", nil, bytes,
       { literal = "HEXTORAW('00FF4100')" })
   add("blobHexBind", "blob", "bl", { "00FF4100", t.string }, bytes)
   add("blobEmpty", "blob", "bl", nil, "", { literal = "EMPTY_BLOB()" })
   add("blobNull", "blob", "bl", t.null, nil, null)
   add("blobFetchNa", "blob", "bl", { "00FF4100", t.string }, bytes,
       { fetchMode = "na" })
   -- 100000 bytes, more than one read piece in the driver.
   add("blobLarge", "blob", "bl", nil,
       string.rep("\xDE\xAD\xBE\xEF", 25000),
       { write = "blobLargeInsert", needs = { "blobLargeInsert" },
         writeParams = { { "DEADBEEF", t.string }, { 25000, t.int } } })

   -- JSON: written as text, read as compact text (key order kept,
   -- numbers normalized, \u escapes as UTF-8) and compared with the
   -- text of the server.
   local function json(extra)
      extra = extra or {}
      extra.checkText = "jsonAsText"
      return extra
   end
   local jsonLong = '{"t":"' .. string.rep("x", 20000) .. '"}'
   add("jsonCompact", "json", "js",
       { '{"b" : 1.0, "a" : [1, 2e2, -0.5, true, null],'
            .. ' "s" : "\\u00e4\\u20ac"}', t.string },
       '{"b":1,"a":[1,200,-0.5,true,null],"s":"\u{E4}\u{20AC}"}', json())
   add("jsonUtf8", "json", "js", { '{"s" : "' .. utf8Text .. '"}', t.string },
       '{"s":"' .. utf8Text .. '"}', json())
   add("jsonLiteral", "json", "js", nil, '{"x":[true,false]}',
       json({ literal = "JSON('{\"x\" : [true, false]}')" }))
   -- More than one read piece of 16384 characters.
   add("jsonLarge", "json", "js", nil,
       '{"t":"ab' .. string.rep("cd", 9999) .. '"}',
       json({ literal = "JSON_OBJECT('t' VALUE RPAD(TO_CLOB('ab'), 20000,"
                 .. " 'cd') RETURNING JSON)" }))
   add("jsonLargeBind", "json", "js", { jsonLong, t.string }, jsonLong,
       json())
   add("jsonDuplicate", "json", "js", { '{"a":1,"a":2}', t.string }, nil,
       json({ expectError = true }))
   add("jsonInvalid", "json", "js", { '{"a":', t.string }, nil,
       json({ expectError = true }))
   add("jsonEmpty", "json", "js", { "", t.string }, "", json())
   add("jsonNull", "json", "js", t.null, nil, json({ nullResult = true }))
   add("jsonFetchNa", "json", "js", { '{"a" : 1}', t.string }, '{"a":1}',
       json({ fetchMode = "na" }))

   add("clobAscii", "clob", "c", { asciiClob, t.string }, asciiClob)
   add("clobNull", "clob", "c", t.null, nil, null)
   add("clobUtf8", "clob", "c", { utf8Clob, t.string }, utf8Clob)
   add("clobZero", "clob", "c", { zeroClob, t.string }, zeroClob)
   add("clobFetchNa", "clob", "c", { utf8Clob, t.string }, utf8Clob,
       { fetchMode = "na" })
   add("nclobUtf8", "clob", "nc", { utf8Clob, t.string }, utf8Clob)
   add("nclobNull", "clob", "nc", t.null, nil, null)
   add("clobLarge", "clob", "c", { largeClob, t.string }, largeClob)
   -- An emoji takes two UTF-16 code units, which LOB lengths and offsets
   -- count. 40001 code units cross the driver's read pieces of 16384
   -- several times; with the leading "a" each piece border falls into a
   -- pair, without it between two pairs.
   local pairsText = string.rep("\u{1F600}", 20000)
   add("clobPairSplit", "clob", "c", { "a" .. pairsText, t.string },
       "a" .. pairsText)
   add("clobPairs", "clob", "c", { pairsText, t.string }, pairsText)
   add("nclobPairSplit", "clob", "nc", { "a" .. pairsText, t.string },
       "a" .. pairsText)
   add("nclobPairs", "clob", "nc", { pairsText, t.string }, pairsText)

   -- Several rows in one cursor; a cell is { param, expected }.
   local nullCell = { t.null }
   local function text(value)
      return { { value, t.string }, value }
   end
   local function rows(columns, rowList, extra)
      extra = extra or {}
      extra.columns = columns
      extra.rows = rowList
      extra.needs = { "typesInsertColumns", "typesRangeSelect" }
      return extra
   end
   local deadBeef = { { string.rep("DEADBEEF", 500), t.string },
                      string.rep("\xDE\xAD\xBE\xEF", 500) }
   local zeroByte = { { "00", t.string }, "\0" }
   add("rowsString", "rows", "s", nil, nil, rows({ "s" }, {
      { text(string.rep("x", 3000)) }, { text("ab") }, { nullCell },
      { text(string.rep("\u{E4}", 1000)) }, { nullCell }, { text("z") },
   }))
   add("rowsNumber", "rows", "n", nil, nil, rows({ "n" }, {
      { { { 42, t.int }, 42 } }, { nullCell }, { { { 0.5, t.number }, 0.5 } },
      { { { -7, t.int }, -7 } }, { nullCell },
   }))
   add("rowsTimestamp", "rows", "ts", nil, nil, rows({ "ts" }, {
      { { { "2026-10-19 13:45:30.5", t.timestamp },
          "2026-10-19 13:45:30.500000" } },
      { nullCell },
      { { { "2000-01-01 00:00:00", t.timestamp },
          "2000-01-01 00:00:00.000000" } },
   }))
   add("rowsClob", "rows", "c", nil, nil, rows({ "c" }, {
      { text(largeClob) }, { nullCell }, { text("x") }, { nullCell },
      { text(utf8Clob) },
   }))
   add("rowsNclob", "rows", "nc", nil, nil, rows({ "nc" }, {
      { text(utf8Clob) }, { nullCell }, { text(largeClob) }, { nullCell },
      { text("y") },
   }))
   add("rowsBlob", "rows", "bl", nil, nil, rows({ "bl" }, {
      { deadBeef }, { nullCell }, { zeroByte }, { nullCell }, { deadBeef },
   }))
   add("rowsRaw", "rows", "rw", nil, nil, rows({ "rw" }, {
      { deadBeef }, { nullCell }, { zeroByte }, { nullCell },
   }))
   add("rowsJson", "rows", "js", nil, nil, rows({ "js" }, {
      { text(jsonLong) }, { nullCell }, { text('{"a":1}') }, { nullCell },
   }))
   -- All columns at once, read with both kinds of keys.
   add("rowsColumnsNa", "rows", "n", nil, nil, rows(
      { "n", "s", "d", "c", "bl", "js" }, {
         { { { 1, t.int }, 1 }, text("a"),
           { { "2026-10-19", t.date }, "2026-10-19 00:00:00" },
           text(utf8Clob), deadBeef, text('{"a":1}') },
         { nullCell, nullCell, nullCell, nullCell, nullCell, nullCell },
         { nullCell, text("b"), nullCell, text("c"), nullCell,
           text(jsonLong) },
      }, { fetchMode = "na" }))

   add("long", "unsupported", nil, nil, nil, { unsupported = "long" })
   add("longRaw", "unsupported", nil, nil, nil, { unsupported = "longRaw" })
   return list
end

-- Count with a noun, singular for 1: "1 limit", "2 limits".
local function plural(count, noun)
   return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

-- Bytes of a string of hex digits.
local function fromHex(hex)
   local bytes = hex:gsub("%x%x", function(digits)
      return string.char(tonumber(digits, 16))
   end)
   return bytes
end

-- Short readable form of a value for messages; binary data (not valid
-- UTF-8) as hex digits.
local function describe(value)
   if type(value) == "number" then
      if math.type(value) == "integer" then
         return string.format("%d (integer)", value)
      end
      return string.format("%.17g (float)", value)
   elseif type(value) == "string" and not utf8.len(value) then
      local hex = value:sub(1, 12):gsub(".", function(byte)
         return string.format("%02X", byte:byte())
      end)
      return string.format("0x%s%s (%d bytes)", hex,
                           #value > 12 and "..." or "", #value)
   elseif type(value) == "string" then
      -- At most 24 characters, cut at a character border.
      local shown = value
      local cut = utf8.offset(value, 25)
      if cut and cut <= #value then
         shown = value:sub(1, cut - 1) .. "..."
      end
      return string.format("%q (%d bytes)", shown, #value)
   end
   return tostring(value)
end

-- Compares a read value with the expected one, depending on the number
-- mode of the connection (nil if the driver has none). Returns "exact",
-- "close" (float mode only: within the tolerance, but not exact) or nil.
local function compare(mode, value, expected)
   if type(value) ~= "number" or type(expected) ~= "number" then
      return value == expected and "exact" or nil
   end
   -- NaN is not equal to anything, not even to itself.
   if expected ~= expected then
      return value ~= value and "exact" or nil
   end
   if mode == "float" then
      if math.type(value) ~= "float" then
         return nil
      end
      if value == expected then
         return "exact"
      end
      -- As float first: math.abs(math.mininteger) overflows.
      local scale = math.abs(expected + 0.0)
      if math.abs(value - expected) <= scale * floatModeTolerance then
         return "close"
      end
      return nil
   end
   if value ~= expected then
      return nil
   end
   if mode == "exact" and math.type(value) ~= math.type(expected) then
      return nil
   end
   return "exact"
end

local function prepare(conn, sql)
   local stmt, err = conn:prepare(sql)
   if not stmt then
      error("prepare: " .. tostring(err), 0)
   end
   return stmt
end

local function closeStatement(stmt)
   local ok, err = stmt:close()
   if not ok then
      error("close statement: " .. tostring(err), 0)
   end
end

-- Executes a statement with parameters.
-- Returns true, or nil and an error message.
local function executeStatement(ctx, sql, params)
   local stmt = prepare(ctx.testConn, sql)
   local result, err = stmt:execute(params)
   closeStatement(stmt)
   if result == nil then
      return nil, tostring(err)
   end
   return true
end

-- Writes the value of a case into row id.
-- Returns true, or nil and an error message.
local function writeValue(ctx, id, case)
   local sql, params
   if case.literal then
      sql = string.format(ctx.backend.typesInsertLiteral, case.column,
                          case.literal)
      params = { { id, ctx.types.int } }
   elseif case.write then
      sql = string.format(ctx.backend[case.write], case.column)
      params = { { id, ctx.types.int }, table.unpack(case.writeParams) }
   else
      sql = string.format(ctx.backend.typesInsert, case.column)
      params = { { id, ctx.types.int }, case.param }
   end
   return executeStatement(ctx, sql, params)
end

-- Fetches the only row of a cursor with the given fetch mode (nil for
-- fetch({})); name is the column name for the named modes.
-- Returns true and the value, or nil and an error message.
local function fetchValue(cur, fetchMode, name)
   if fetchMode == "multi" then
      local value, err = cur:fetch()
      if value == nil then
         return nil, err and tostring(err) or "row not found"
      end
      return true, value
   end
   local row, err
   if fetchMode == "a" or fetchMode == "na" then
      row, err = cur:fetch({}, fetchMode)
   else
      row, err = cur:fetch({})
   end
   if row == nil then
      return nil, err and tostring(err) or "row not found"
   end
   if fetchMode == "a" then
      return true, row[name]
   end
   if fetchMode == "na" and row[1] ~= row[name] then
      return nil, string.format("numeric key gives %s, named key %s",
                                describe(row[1]), describe(row[name]))
   end
   return true, row[1]
end

-- Runs a query with parameters and fetches the only row (see
-- fetchValue). Returns true and the value, or nil and an error message.
-- The third result is the column type the driver reports.
local function queryValue(ctx, sql, params, fetchMode, name)
   local stmt = prepare(ctx.testConn, sql)
   local cur, err = stmt:execute(params)
   if not cur then
      closeStatement(stmt)
      return nil, tostring(err)
   end
   local columnTypes = cur.getcoltypes and cur:getcoltypes()
   local ok, value = fetchValue(cur, fetchMode, name)
   -- Closes a cursor that is still open; the result does not matter.
   cur:close()
   closeStatement(stmt)
   return ok, value, columnTypes and columnTypes[1]
end

-- Returns a message if the reported column type is not the expected
-- one, nil if it matches or nothing is expected.
local function columnTypeProblem(expected, actual)
   if expected == nil or actual == expected then
      return nil
   end
   return string.format("column type %s, expected %s", tostring(actual),
                        expected)
end

-- Reads an expression of row id. Returns true and the value (nil for
-- NULL), or nil and an error message.
-- The third result is the column type the driver reports.
local function readValue(ctx, id, expression, fetchMode)
   local sql = string.format(ctx.backend.typesSelect, expression)
   return queryValue(ctx, sql, { { id, ctx.types.int } }, fetchMode,
                     expression)
end

-- Runs a ROWID case: inserts row id, reads its ROWID and finds the row
-- again with it. With case.iot the row goes into the index organized
-- table (logical ROWID); with case.store the ROWID is written into the
-- column of the case first and read back from there.
-- Returns "pass", or "fail" and a message.
local function runRowidCase(ctx, id, case)
   local backend = ctx.backend
   local int, str = ctx.types.int, ctx.types.string
   local tableName = case.iot and backend.iotTable or backend.typesTable
   local ok, err
   if case.iot then
      ok, err = executeStatement(ctx, backend.iotInsert, { { id, int } })
   else
      ok, err = executeStatement(ctx, string.format(backend.typesInsert,
         "n"), { { id, int }, { 1, int } })
   end
   if not ok then
      return "fail", "insert: " .. err
   end
   local columnTypes = backend.columnTypes or {}
   local rowid, rowidType
   ok, rowid, rowidType = queryValue(ctx, string.format(backend.rowidSelect,
      tableName), { { id, int } })
   if not ok then
      return "fail", "read ROWID: " .. rowid
   end
   if type(rowid) ~= "string" or rowid == "" then
      return "fail", "ROWID read as " .. describe(rowid)
   end
   local problem = columnTypeProblem(columnTypes.rowid, rowidType)
   if problem then
      return "fail", "ROWID: " .. problem
   end

   if case.store then
      ctx.nextId = ctx.nextId + 1
      local storeId = ctx.nextId
      ok, err = executeStatement(ctx, string.format(backend.typesInsert,
         case.column), { { storeId, int }, { rowid, str } })
      if not ok then
         return "fail", "write: " .. err
      end
      local stored, storedType
      ok, stored, storedType = readValue(ctx, storeId, case.column)
      if not ok then
         return "fail", "read: " .. stored
      end
      problem = columnTypeProblem(columnTypes[case.column], storedType)
      if problem then
         return "fail", problem
      end
      if stored ~= rowid then
         return "fail", string.format("wrote %s, read back %s", rowid,
                                      describe(stored))
      end
   end

   local found
   ok, found = queryValue(ctx, string.format(backend.rowidLookup,
      tableName), { { rowid, str } })
   if not ok then
      return "fail", "find by ROWID " .. rowid .. ": " .. found
   end
   if found ~= id then
      return "fail", string.format("ROWID %s finds %s, not row %d", rowid,
                                   describe(found), id)
   end
   return "pass"
end

-- Returns the reason if the stored value of a number bind is the
-- expected one cut to the significant digits the backend keeps, else nil.
local function numberBindLimit(ctx, case, stored, expected)
   local limits = ctx.backend.limits or {}
   local digits = limits.numberBindDigits
   if not digits or not stored or stored.value == expected
      or type(expected) ~= "number" or type(case.param) ~= "table"
      or case.param[2] ~= ctx.types.number then
      return nil
   end
   local cut = tonumber(string.format("%." .. digits .. "g", expected))
   if stored.value ~= cut then
      return nil
   end
   local reason = limits.numberBind
   -- The hint only helps for values that luasql.type.int can hold.
   if limits.numberBindHint and math.tointeger(expected) then
      reason = reason .. "; " .. limits.numberBindHint
   end
   return string.format("%s; server has %s", reason, stored.text)
end

-- Runs a case for a column type the driver does not support on purpose:
-- reading must fail with the expected error, not return a value.
-- Returns "limit" and the reason, or "fail" and a message.
local function runUnsupportedCase(ctx, id, case)
   local spec = ctx.backend.unsupportedTypes[case.unsupported]
   local params = { { id, ctx.types.int } }
   local ok, err = executeStatement(ctx, spec.insert, params)
   if not ok then
      return "fail", "insert: " .. err
   end
   local value
   ok, value = queryValue(ctx, spec.select, params)
   if ok then
      return "fail", "read " .. describe(value) .. ", expected an error"
   end
   if not value:find(spec.errorPattern, 1, true) then
      return "fail", "unexpected error: " .. value
   end
   return "limit", spec.reason
end

-- Runs a rows case: writes case.rows into consecutive rows starting at
-- id (one cell { param, expected } per column of case.columns), reads
-- them back in one cursor and compares cell by cell.
-- Returns "pass", or "fail" and a message.
local function runRowsCase(ctx, id, case)
   local backend = ctx.backend
   local int = ctx.types.int
   local placeholders = {}
   for k = 1, #case.columns do
      placeholders[k] = ":" .. (k + 1)
   end
   local columnList = table.concat(case.columns, ", ")
   local insert = string.format(backend.typesInsertColumns, columnList,
                                table.concat(placeholders, ", "))
   local lastId = id + #case.rows - 1
   ctx.nextId = lastId
   for k, row in ipairs(case.rows) do
      local params = { { id + k - 1, int } }
      for c, cell in ipairs(row) do
         params[c + 1] = cell[1]
      end
      local ok, err = executeStatement(ctx, insert, params)
      if not ok then
         return "fail", string.format("insert row %d: %s", k, err)
      end
   end

   local stmt = prepare(ctx.testConn,
      string.format(backend.typesRangeSelect, columnList))
   local cur, err = stmt:execute({ { id, int }, { lastId, int } })
   if not cur then
      closeStatement(stmt)
      return "fail", "select: " .. tostring(err)
   end
   local mode = case.fetchMode or "n"
   local count, problem = 0, nil
   local row
   row, err = cur:fetch({}, mode)
   while row ~= nil and problem == nil do
      count = count + 1
      local cells = case.rows[count]
      if cells == nil then
         problem = "more rows than written"
         break
      end
      for c, name in ipairs(case.columns) do
         local value = mode == "a" and row[name] or row[c]
         local expected = cells[c][2]
         if mode == "na" and row[c] ~= row[name] then
            problem = string.format("row %d, %s: numeric key gives %s,"
               .. " named key %s", count, name, describe(row[c]),
               describe(row[name]))
         elseif not compare(ctx.numberMode, value, expected) then
            problem = string.format("row %d, %s: expected %s, got %s",
               count, name, describe(expected), describe(value))
         end
         if problem then
            break
         end
      end
      if problem == nil then
         row, err = cur:fetch({}, mode)
      end
   end
   -- Closes a cursor that is still open; the result does not matter.
   cur:close()
   closeStatement(stmt)
   if problem then
      return "fail", problem
   end
   if err ~= nil then
      return "fail", "fetch: " .. tostring(err)
   end
   if count ~= #case.rows then
      return "fail", string.format("expected %d rows, got %d", #case.rows,
                                   count)
   end
   return "pass"
end

-- Runs one case. Returns "pass", or "limit" or "fail" and a message.
local function runCase(ctx, id, case)
   if case.rowid then
      return runRowidCase(ctx, id, case)
   end
   if case.unsupported then
      return runUnsupportedCase(ctx, id, case)
   end
   if case.rows then
      return runRowsCase(ctx, id, case)
   end
   local ok, err = writeValue(ctx, id, case)
   if not ok then
      if case.expectError or case.errorAllowed then
         return "pass"
      end
      if case.limitError and err:find(case.limitError) then
         return "limit", case.limitReason
      end
      return "fail", "write: " .. err
   end
   if case.expectError then
      return "fail", "expected an error, the value was stored"
   end

   local value
   local expression = case.readExpression or case.column
   local columnType
   ok, value, columnType = readValue(ctx, id, expression, case.fetchMode)
   if not ok then
      return "fail", "read: " .. value
   end
   local expectedType = case.columnType
   if expectedType == nil and case.readExpression == nil then
      expectedType = (ctx.backend.columnTypes or {})[case.column]
   end
   local problem = columnTypeProblem(expectedType, columnType)
   if problem then
      return "fail", problem
   end

   local stored
   if case.checkServer then
      local textOk, text = readValue(ctx, id,
         string.format(ctx.backend.numberAsText, case.column))
      if textOk then
         stored = { text = tostring(text), value = tonumber(text) }
      else
         stored = { text = "unknown (" .. tostring(text) .. ")" }
      end
   end
   local textQuery = case.checkText and ctx.backend[case.checkText]
   if textQuery then
      local textOk, text = readValue(ctx, id,
         string.format(textQuery, expression))
      if textOk then
         stored = { text = describe(text), value = text }
      else
         stored = { text = "unknown (" .. tostring(text) .. ")" }
      end
   end
   if case.checkHex and ctx.backend.rawAsHex then
      local hexOk, hex = readValue(ctx, id,
         string.format(ctx.backend.rawAsHex, case.column))
      if hexOk then
         local bytes = hex and fromHex(hex)
         stored = { text = describe(bytes), value = bytes }
      else
         stored = { text = "unknown (" .. tostring(hex) .. ")" }
      end
   end

   local expected = case.expected
   if case.nullResult then
      expected = nil
   end
   -- A value made on the server is known only from there.
   if case.expectedLength and stored then
      expected = stored.value
      if type(expected) ~= "string" or #expected ~= case.expectedLength then
         return "fail", string.format("expected %d bytes, server has %s",
                                      case.expectedLength, stored.text)
      end
   end
   -- At a known bind limit the read is judged against the stored value.
   -- Without conversion by the client library, the read value is the
   -- stored one.
   local bindStored = stored
   if case.exactRead and type(value) == "number" then
      bindStored = { value = value, text = string.format("%.17g", value) }
   end
   local limitReason = numberBindLimit(ctx, case, bindStored, expected)
   if limitReason then
      expected = bindStored.value
   end

   local match = compare(ctx.numberMode, value, expected)
   -- Values the client library does not convert must be exact.
   if match == "close" and case.exactRead then
      match = nil
   end
   local storedOk = stored == nil or stored.value == expected
   if match and storedOk then
      if match == "close" then
         local limits = ctx.backend.limits or {}
         local reason = limits.floatRead or "float mode: not exact"
         -- The nearest double to an integer is a limit of the type, not
         -- a rounding error of the client library.
         local exact = stored and stored.value or expected
         if limits.doubleInteger and math.type(expected) == "integer"
            and value == exact + 0.0 then
            reason = limits.doubleInteger
         end
         reason = string.format("%s; got %s", reason, describe(value))
         limitReason = limitReason and (limitReason .. "; " .. reason)
            or reason
      end
      if limitReason then
         return "limit", limitReason
      end
      return "pass"
   end
   if case.limitNull and value == nil
      and (stored == nil or stored.value == nil) then
      return "limit", case.limitReason
   end

   if match then
      return "fail", "read back correctly, but server has " .. stored.text
   end
   local message = string.format("expected %s, got %s",
                                 describe(expected), describe(value))
   if stored and storedOk then
      message = message .. "; stored correctly as " .. stored.text
         .. ", lost while reading"
   elseif stored then
      message = message .. "; server has " .. stored.text
         .. ", lost while binding"
   end
   return "fail", message
end

-- Returns why a case is skipped, or nil.
local function skipReason(ctx, case)
   if case.skip then
      return case.skip
   end
   if case.column and not ctx.columns[case.column] then
      return "backend has no column " .. case.column
   end
   for _, column in ipairs(case.columns or {}) do
      if not ctx.columns[column] then
         return "backend has no column " .. column
      end
   end
   for _, key in ipairs(case.needs or {}) do
      if not ctx.backend[key] then
         return "backend has no " .. key
      end
   end
   if case.unsupported
      and not (ctx.backend.unsupportedTypes or {})[case.unsupported] then
      return "backend has no unsupported type " .. case.unsupported
   end
   if case.needsTimeZone and not ctx.timeZoneSet then
      return "session time zone not set"
   end
   if case.literal and not ctx.backend.typesInsertLiteral then
      return "backend has no typesInsertLiteral"
   end
   return nil
end

-- Runs a case; one with sessionTimeZone runs in that session time zone,
-- and testTimeZone is set again afterwards.
local function runCaseInZone(ctx, id, case)
   if not case.sessionTimeZone then
      return runCase(ctx, id, case)
   end
   local set = ctx.backend.sessionSettings.timeZone.set
   local ok, err = dbutil.exec(ctx.testConn,
                               string.format(set, case.sessionTimeZone))
   if not ok then
      return "fail", string.format("cannot set session time zone %s: %s",
                                   case.sessionTimeZone, err)
   end
   local runOk, status, message = pcall(runCase, ctx, id, case)
   ok, err = dbutil.exec(ctx.testConn, string.format(set, testTimeZone))
   if not runOk then
      error(status, 0)
   end
   if not ok then
      return "fail", "cannot restore session time zone: " .. err
   end
   return status, message
end

-- Runs all cases of the given blocks, prints failures, limits, skips
-- and a summary. Adds the limits to ctx.limitCount and returns the number
-- of failed cases.
local function runBlock(ctx, title, cases, blocks)
   print("  " .. title .. ":")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   for _, case in ipairs(cases) do
      if blocks[case.block] then
         local prefix = string.format("    %-17s ", case.name)
         local reason = skipReason(ctx, case)
         if reason then
            skipped = skipped + 1
            report.print(prefix, "skipped: " .. reason, "skip")
         else
            ctx.nextId = ctx.nextId + 1
            local ok, status, message = pcall(runCaseInZone, ctx,
                                              ctx.nextId, case)
            if not ok then
               status, message = "fail", status
            end
            if status == "pass" then
               passed = passed + 1
               if report.verbose then
                  report.print(prefix, "passed", "pass")
               end
            elseif status == "limit" then
               limits = limits + 1
               report.print(prefix, "limit: " .. tostring(message), "limit")
            else
               failed = failed + 1
               report.print(prefix, "FAILED: " .. tostring(message), "fail")
            end
         end
      end
   end
   report.print("    ", string.format("%d passed, %s, %d failed, %d skipped",
                                    passed, plural(limits, "limit"), failed,
                                    skipped), failed > 0 and "fail" or "pass")
   ctx.limitCount = ctx.limitCount + limits
   return failed
end

-- Sets a session setting of the backend. Returns the old value, or nil
-- and an error message.
local function changeSetting(ctx, name, value)
   local settings = ctx.backend.sessionSettings or {}
   local setting = settings[name]
   if not setting then
      return nil, "backend has no session setting " .. name
   end
   local old, err = dbutil.queryValue(ctx.testConn, setting.query)
   if old == nil then
      return nil, err
   end
   local ok
   ok, err = dbutil.exec(ctx.testConn, string.format(setting.set, value))
   if not ok then
      return nil, err
   end
   return old
end

local function restoreSetting(ctx, name, old)
   local setting = ctx.backend.sessionSettings[name]
   local ok, err = dbutil.exec(ctx.testConn, string.format(setting.set, old))
   if not ok then
      report.print("  warning: ",
                   string.format("cannot restore %s: %s", name, err), "note")
   end
end

-- Switches the number mode of the test connection; affects cursors
-- opened afterwards. Raises an error on failure.
local function setNumberMode(ctx, mode)
   local ok, err = ctx.testConn:setoption("numbers", mode)
   if not ok then
      error(string.format("cannot set number mode %s: %s",
                          mode, tostring(err)), 0)
   end
   ctx.numberMode = mode
end

-- Runs all blocks. Returns the number of failed cases.
local function runBlocks(ctx, cases)
   local failed = 0

   local oldTimeZone, err = changeSetting(ctx, "timeZone", testTimeZone)
   ctx.timeZoneSet = oldTimeZone ~= nil
   if not oldTimeZone then
      report.print("  note: ", "time zone not set: " .. tostring(err),
                   "note")
   end

   local settings = ctx.backend.sessionSettings or {}
   local locale = settings.locale
   local localeValues = locale and locale.testValues or { false }
   local typeBlocks = { numbers = true, dates = true, booleans = true }
   for _, value in ipairs(localeValues) do
      local title = "numbers, dates, booleans"
      local oldLocale
      if value then
         title = string.format("%s, %s = %s", title, locale.label, value)
         oldLocale, err = changeSetting(ctx, "locale", value)
      end
      if value and not oldLocale then
         report.print("  ", string.format("cannot set %s = %s: %s",
                                          locale.label, value,
                                          tostring(err)), "fail")
         failed = failed + 1
      else
         failed = failed + runBlock(ctx, title, cases, typeBlocks)
      end
      if oldLocale then
         restoreSetting(ctx, "locale", oldLocale)
      end
   end

   if ctx.numberMode then
      local oldMode = ctx.numberMode
      setNumberMode(ctx, "float")
      local ok, result = pcall(runBlock, ctx, "numbers, float mode", cases,
                               { numbers = true })
      setNumberMode(ctx, oldMode)
      if not ok then
         error(result, 0)
      end
      failed = failed + result
   end

   failed = failed + runBlock(ctx, "strings", cases, { strings = true })
   failed = failed + runBlock(ctx, "rowids", cases, { rowids = true })
   failed = failed + runBlock(ctx, "raw", cases, { raw = true })
   if oldTimeZone then
      restoreSetting(ctx, "timeZone", oldTimeZone)
   end
   failed = failed + runBlock(ctx, "clob", cases, { clob = true })
   failed = failed + runBlock(ctx, "blob", cases, { blob = true })
   failed = failed + runBlock(ctx, "json", cases, { json = true })
   failed = failed + runBlock(ctx, "rows", cases, { rows = true })
   failed = failed + runBlock(ctx, "unsupported", cases,
                              { unsupported = true })
   return failed
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function dataTypes.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      report.print("  ", "skipped: driver has no prepare()", "skip")
      return true
   end
   if backend.typesTableCreate == nil then
      report.print("  ", "skipped: backend has no test table", "skip")
      return true
   end

   local typesCtx = {
      testConn = conn,
      backend = backend,
      types = ctx.driver.type,
      columns = {},
      nextId = 0,
      limitCount = 0,
      timeZoneSet = false,
   }
   -- nil if the driver has no number modes.
   if conn.getoption and conn.setoption then
      typesCtx.numberMode = conn:getoption("numbers")
   end
   for _, column in ipairs(backend.typesColumns) do
      typesCtx.columns[column] = true
   end
   local cases = makeCases(typesCtx.types)
   local overrides = backend.typeCaseOverrides or {}
   for _, case in ipairs(cases) do
      for key, value in pairs(overrides[case.name] or {}) do
         case[key] = value
      end
   end

   -- Tables left behind by an aborted run are dropped first.
   local tables = { { backend.typesTableCreate, backend.typesTableDrop } }
   if backend.iotTableCreate then
      tables[#tables + 1] = { backend.iotTableCreate, backend.iotTableDrop }
   end
   for _, spec in pairs(backend.unsupportedTypes or {}) do
      tables[#tables + 1] = { spec.create, spec.drop }
   end
   local function dropTables()
      for _, statements in ipairs(tables) do
         local ok, err = dbutil.exec(conn, statements[2])
         if not ok then
            report.print("  warning: ", "cannot drop test table: " .. err,
                         "note")
         end
      end
   end
   for _, statements in ipairs(tables) do
      dbutil.exec(conn, statements[2])
      local ok, err = dbutil.exec(conn, statements[1])
      if not ok then
         dropTables()
         return nil, "creating test table: " .. err
      end
   end

   local runOk, result = pcall(runBlocks, typesCtx, cases)
   dropTables()

   if not runOk then
      return nil, tostring(result)
   end
   if result > 0 then
      return nil, plural(result, "case") .. " failed"
   end
   if typesCtx.limitCount > 0 then
      return true, plural(typesCtx.limitCount, "known limitation")
   end
   return true
end

return dataTypes
