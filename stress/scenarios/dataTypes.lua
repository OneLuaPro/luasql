-- scenarios/dataTypes.lua
-- Writes values of many types through prepared statements into a test
-- table, reads them back and compares. Checks correctness at type
-- boundaries, not leaks; every case runs once, independent of the tier.
--
-- Blocks, in this order:
--   numbers, dates, booleans  once per test locale of the backend
--                             (decimal comma, date format); the session
--                             locale must not change any result
--   numbers, float mode       again with conn:setoption("numbers",
--                             "float"), if the driver has it
--   strings                   multibyte, length limit, empty, \0,
--                             national character set
--   clob                      last: a failed LOB read may leave the
--                             session unusable
--
-- Number cases also read the stored value as text on the server and
-- convert it with tonumber. That tells whether a wrong result was lost
-- while binding or while reading. In exact mode a number must also have
-- the expected subtype (integer or float); in float mode every number
-- must be a float close to the expected value.
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
-- ("a", "na" or "multi").
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
      for key, value in pairs(extra or {}) do
         case[key] = value
      end
      list[#list + 1] = case
   end
   local null = { nullResult = true }
   local fails = { expectError = true }

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
   add("numberNull", "numbers", "n", t.null, nil, null)
   add("intFetchNa", "numbers", "n", { 42, t.int }, 42,
       { fetchMode = "na" })
   add("floatFetchMulti", "numbers", "n", { 0.25, t.number }, 0.25,
       { fetchMode = "multi" })

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
   add("timestampLtz", "dates", "tsltz",
       { "2026-10-19 13:45:30", t.timestamp },
       "2026-10-19 13:45:30.000000", { needsTimeZone = true })
   add("dateNull", "dates", "d", t.null, nil, null)

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

   add("clobAscii", "clob", "c", { asciiClob, t.string }, asciiClob)
   add("clobNull", "clob", "c", t.null, nil, null)
   add("clobUtf8", "clob", "c", { utf8Clob, t.string }, utf8Clob)
   add("clobZero", "clob", "c", { zeroClob, t.string }, zeroClob)
   add("clobFetchNa", "clob", "c", { utf8Clob, t.string }, utf8Clob,
       { fetchMode = "na" })
   add("nclobUtf8", "clob", "nc", { utf8Clob, t.string }, utf8Clob)
   add("nclobNull", "clob", "nc", t.null, nil, null)
   add("clobLarge", "clob", "c", { largeClob, t.string }, largeClob)
   return list
end

-- Count with a noun, singular for 1: "1 limit", "2 limits".
local function plural(count, noun)
   return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

-- Short readable form of a value for messages.
local function describe(value)
   if type(value) == "number" then
      if math.type(value) == "integer" then
         return string.format("%d (integer)", value)
      end
      return string.format("%.17g (float)", value)
   elseif type(value) == "string" then
      local shown = value
      if #shown > 24 then
         shown = shown:sub(1, 24) .. "..."
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

-- Writes the value of a case into row id.
-- Returns true, or nil and an error message.
local function writeValue(ctx, id, case)
   local sql, params
   if case.literal then
      sql = string.format(ctx.backend.typesInsertLiteral, case.column,
                          case.literal)
      params = { { id, ctx.types.int } }
   else
      sql = string.format(ctx.backend.typesInsert, case.column)
      params = { { id, ctx.types.int }, case.param }
   end
   local stmt = prepare(ctx.testConn, sql)
   local result, err = stmt:execute(params)
   closeStatement(stmt)
   if result == nil then
      return nil, tostring(err)
   end
   return true
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

-- Reads an expression of row id. Returns true and the value (nil for
-- NULL), or nil and an error message.
local function readValue(ctx, id, expression, fetchMode)
   local stmt = prepare(ctx.testConn,
      string.format(ctx.backend.typesSelect, expression))
   local cur, err = stmt:execute({ { id, ctx.types.int } })
   if not cur then
      closeStatement(stmt)
      return nil, tostring(err)
   end
   local ok, value = fetchValue(cur, fetchMode, expression)
   -- Closes a cursor that is still open; the result does not matter.
   cur:close()
   closeStatement(stmt)
   return ok, value
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

-- Runs one case. Returns "pass", or "limit" or "fail" and a message.
local function runCase(ctx, id, case)
   local ok, err = writeValue(ctx, id, case)
   if not ok then
      if case.expectError or case.errorAllowed then
         return "pass"
      end
      return "fail", "write: " .. err
   end
   if case.expectError then
      return "fail", "expected an error, the value was stored"
   end

   local value
   ok, value = readValue(ctx, id, case.column, case.fetchMode)
   if not ok then
      return "fail", "read: " .. value
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

   local expected = case.expected
   if case.nullResult then
      expected = nil
   end
   -- At a known bind limit the read is judged against the stored value.
   local limitReason = numberBindLimit(ctx, case, stored, expected)
   if limitReason then
      expected = stored.value
   end

   local match = compare(ctx.numberMode, value, expected)
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
   if case.limitNull and value == nil and storedOk then
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
   if not ctx.columns[case.column] then
      return "backend has no column " .. case.column
   end
   if case.needsTimeZone and not ctx.timeZoneSet then
      return "session time zone not set"
   end
   if case.literal and not ctx.backend.typesInsertLiteral then
      return "backend has no typesInsertLiteral"
   end
   return nil
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
            report.print(prefix, "skipped: " .. reason)
         else
            ctx.nextId = ctx.nextId + 1
            local ok, status, message = pcall(runCase, ctx, ctx.nextId, case)
            if not ok then
               status, message = "fail", status
            end
            if status == "pass" then
               passed = passed + 1
            elseif status == "limit" then
               limits = limits + 1
               report.print(prefix, "limit: " .. tostring(message))
            else
               failed = failed + 1
               report.print(prefix, "FAILED: " .. tostring(message))
            end
         end
      end
   end
   print(string.format("    %d passed, %s, %d failed, %d skipped",
                       passed, plural(limits, "limit"), failed, skipped))
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
                   string.format("cannot restore %s: %s", name, err))
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
      report.print("  note: ", "time zone not set: " .. tostring(err))
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
                                          tostring(err)))
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
   if oldTimeZone then
      restoreSetting(ctx, "timeZone", oldTimeZone)
   end
   failed = failed + runBlock(ctx, "clob", cases, { clob = true })
   return failed
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function dataTypes.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      print("  skipped: driver has no prepare()")
      return true
   end
   if backend.typesTableCreate == nil then
      print("  skipped: backend has no test table")
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

   -- A table left behind by an aborted run is dropped first.
   dbutil.exec(conn, backend.typesTableDrop)
   local ok, err = dbutil.exec(conn, backend.typesTableCreate)
   if not ok then
      return nil, "creating test table: " .. err
   end

   local runOk, result = pcall(runBlocks, typesCtx, cases)
   ok, err = dbutil.exec(conn, backend.typesTableDrop)
   if not ok then
      report.print("  warning: ", "cannot drop test table: " .. err)
   end

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
