-- scenarios/dataTypes.lua
-- Writes values of many types through prepared statements into a test
-- table, reads them back and compares. Checks correctness at type
-- boundaries, not leaks; every case runs once, independent of the tier.
--
-- Blocks, in this order:
--   numbers, dates, booleans  once per test locale of the backend
--                             (decimal comma, date format); the session
--                             locale must not change any result
--   strings                   multibyte, length limit, empty, \0
--   clob                      last: a failed LOB read may leave the
--                             session unusable
--
-- Number cases also read the stored value as text on the server and
-- convert it with tonumber. That tells whether a wrong result was lost
-- while binding or while reading.
--
-- Skipped if the driver has no prepare() or the backend has no test
-- table.

local dbutil = require("dbutil")

local dataTypes = {}

-- Session time zone during the run; the timestamp with time zone case
-- expects this offset.
local testTimeZone = "+02:00"

-- a-umlaut, o-umlaut, u-umlaut (2 bytes each), euro sign (3 bytes) and
-- an emoji (4 bytes).
local utf8Text = "\u{E4}\u{F6}\u{FC}\u{20AC}\u{1F600}"

-- Exactly 4000 bytes: 1333 euro signs of 3 bytes plus one ASCII byte.
local maxBytesText = string.rep("\u{20AC}", 1333) .. "x"

local asciiClob = string.rep("abc", 1000)
local utf8Clob = string.rep(utf8Text, 100)

-- Builds the case list. A case has: name, block, column, param (as for
-- stmt:execute) and expected; optional: nullResult (expect NULL),
-- expectError, errorAllowed (an error is fine, a wrong value is not),
-- needsTimeZone, checkServer (also check the value stored on the server).
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
   add("float", "numbers", "n", { 0.1, t.number }, 0.1)
   add("floatNegative", "numbers", "n", { -123.456, t.number }, -123.456)
   add("floatTiny", "numbers", "n", { 1e-100, t.number }, 1e-100)
   add("floatHuge", "numbers", "n", { 1.5e100, t.number }, 1.5e100)
   add("floatOverflow", "numbers", "n", { 1e200, t.number }, nil, fails)
   add("infinity", "numbers", "n", { math.huge, t.number }, math.huge,
       { errorAllowed = true })
   add("numberNull", "numbers", "n", t.null, nil, null)

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
   add("timestampTz", "dates", "tstz",
       { "2026-10-19 13:45:30", t.timestamp },
       "2026-10-19 13:45:30.000000 " .. testTimeZone,
       { needsTimeZone = true })
   add("dateNull", "dates", "d", t.null, nil, null)

   add("trueAsNumber", "booleans", "n", { true, t.boolean }, 1)
   add("falseAsNumber", "booleans", "n", { false, t.boolean }, 0)
   add("booleanColumn", "booleans", "b", { true, t.boolean }, true)

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

   add("clobAscii", "clob", "c", { asciiClob, t.string }, asciiClob)
   add("clobNull", "clob", "c", t.null, nil, null)
   add("clobUtf8", "clob", "c", { utf8Clob, t.string }, utf8Clob)
   return list
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
   local stmt = prepare(ctx.testConn,
      string.format(ctx.backend.typesInsert, case.column))
   local result, err = stmt:execute({ { id, ctx.types.int }, case.param })
   closeStatement(stmt)
   if result == nil then
      return nil, tostring(err)
   end
   return true
end

-- Reads an expression of row id. Returns true and the value (nil for
-- NULL), or nil and an error message.
local function readValue(ctx, id, expression)
   local stmt = prepare(ctx.testConn,
      string.format(ctx.backend.typesSelect, expression))
   local cur, err = stmt:execute({ { id, ctx.types.int } })
   if not cur then
      closeStatement(stmt)
      return nil, tostring(err)
   end
   local row
   row, err = cur:fetch({})
   -- Closes a cursor that is still open; the result does not matter.
   cur:close()
   closeStatement(stmt)
   if row == nil then
      return nil, err and tostring(err) or "row not found"
   end
   return true, row[1]
end

-- Runs one case. Returns true, or nil and a message.
local function runCase(ctx, id, case)
   local ok, err = writeValue(ctx, id, case)
   if not ok then
      if case.expectError or case.errorAllowed then
         return true
      end
      return nil, "write: " .. err
   end
   if case.expectError then
      return nil, "expected an error, the value was stored"
   end

   local value
   ok, value = readValue(ctx, id, case.column)
   if not ok then
      return nil, "read: " .. value
   end

   local stored
   if case.checkServer then
      local textOk, text = readValue(
	 ctx, id,
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
   local readOk = value == expected
   local storedOk = stored == nil or stored.value == expected
   if readOk and storedOk then
      return true
   end
   if readOk then
      return nil, "read back correctly, but server has " .. stored.text
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
   return nil, message
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
   return nil
end

-- Runs all cases of the given blocks, prints failures, skips and a
-- summary. Returns the number of failed cases.
local function runBlock(ctx, title, cases, blocks)
   print("  " .. title .. ":")
   local passed, failed, skipped = 0, 0, 0
   for _, case in ipairs(cases) do
      if blocks[case.block] then
         local reason = skipReason(ctx, case)
         if reason then
            skipped = skipped + 1
            print(string.format("    %-16s skipped: %s", case.name, reason))
         else
            ctx.nextId = ctx.nextId + 1
            local ok, result, err = pcall(runCase, ctx, ctx.nextId, case)
            if ok and result then
               passed = passed + 1
            else
               failed = failed + 1
               print(string.format("    %-16s FAILED: %s", case.name,
                                   tostring(ok and err or result)))
            end
         end
      end
   end
   print(string.format("    %d passed, %d failed, %d skipped",
                       passed, failed, skipped))
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
      print(string.format("  warning: cannot restore %s: %s", name, err))
   end
end

-- Runs all blocks. Returns the number of failed cases.
local function runBlocks(ctx, cases)
   local failed = 0

   local oldTimeZone, err = changeSetting(ctx, "timeZone", testTimeZone)
   ctx.timeZoneSet = oldTimeZone ~= nil
   if not oldTimeZone then
      print("  note: time zone not set: " .. tostring(err))
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
         print(string.format("  cannot set %s = %s: %s",
                             locale.label, value, tostring(err)))
         failed = failed + 1
      else
         failed = failed + runBlock(ctx, title, cases, typeBlocks)
      end
      if oldLocale then
         restoreSetting(ctx, "locale", oldLocale)
      end
   end

   failed = failed + runBlock(ctx, "strings", cases, { strings = true })
   if oldTimeZone then
      restoreSetting(ctx, "timeZone", oldTimeZone)
   end
   failed = failed + runBlock(ctx, "clob", cases, { clob = true })
   return failed
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true, or nil and an error message.
function dataTypes.run(ctx)
   local backend = ctx.backend
   if ctx.testConn.prepare == nil then
      print("  skipped: driver has no prepare()")
      return true
   end
   if backend.typesTableCreate == nil then
      print("  skipped: backend has no test table")
      return true
   end

   local typesCtx = {
      testConn = ctx.testConn,
      backend = backend,
      types = ctx.driver.type,
      columns = {},
      nextId = 0,
      timeZoneSet = false,
   }
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
   dbutil.exec(ctx.testConn, backend.typesTableDrop)
   local ok, err = dbutil.exec(ctx.testConn, backend.typesTableCreate)
   if not ok then
      return nil, "creating test table: " .. err
   end

   local runOk, result = pcall(runBlocks, typesCtx, cases)
   ok, err = dbutil.exec(ctx.testConn, backend.typesTableDrop)
   if not ok then
      print("  warning: cannot drop test table: " .. err)
   end

   if not runOk then
      return nil, tostring(result)
   end
   if result > 0 then
      return nil, string.format("%d cases failed", result)
   end
   return true
end

return dataTypes
