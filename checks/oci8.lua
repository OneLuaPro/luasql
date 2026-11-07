-- checks/oci8.lua
-- Short functional test of the luasql OCI8 driver against an Oracle database.
-- The password is never printed. Pass it as 3rd argument or, better, via the
-- environment variable ORACLE_TEST_PASSWORD.
--
--   set ORACLE_TEST_PASSWORD=...
--   lua checks/oci8.lua DESKTOP-1HK25HF:1521/FREEPDB1 luatest
--
-- Needs the Oracle Instant Client (oci.dll) in PATH.
-- Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/oci8.lua", "Functional test of the luasql OCI8 driver")
parser:argument("connect", "Easy Connect string, e.g. host:1521/service")
parser:argument("user", "Database user")
parser:argument("passwd", "Password (default: env ORACLE_TEST_PASSWORD)"):args("?")
local args = parser:parse()

local passwd = args.passwd or os.getenv("ORACLE_TEST_PASSWORD")
do
  local odd = passwd:match("^[%s\"']") or passwd:match("[%s\"']$")
  print(string.format("  [INFO] password length %d%s", #passwd,
    odd and ", has a leading/trailing blank or quote!" or ""))
end

local failed = 0
local function check(name, cond, detail)
  if cond then
    print("  [OK] " .. name)
  else
    failed = failed + 1
    print("  [FAIL] " .. name .. (detail and (" -> " .. tostring(detail)) or ""))
  end
end
local function info(name, value)
  print(string.format("  [INFO] %s: %s", name, tostring(value)))
end
local function mask(s)
  if passwd and #passwd > 0 then
    s = tostring(s):gsub(passwd:gsub("%p", "%%%0"), "***")
  end
  return s
end

local TABLE = "lt_oci8"
-- a-umlaut, o-umlaut, u-umlaut, sharp s, euro sign: 5 characters, 11 bytes in UTF-8
local TXT = "\u{E4}\u{F6}\u{FC}\u{DF}\u{20AC}"

print("-- load driver")
local ok, luasql = pcall(require, "luasql.oci8")
check("require luasql.oci8", ok and type(luasql) == "table", luasql)
if not ok or type(luasql) ~= "table" then os.exit(1) end
info("version", luasql._VERSION)

print("-- connect")
local env = assert(luasql.oci8())
local conn, err = env:connect(args.connect, args.user, passwd)
check("connect", conn ~= nil, err and mask(err))
if not conn then os.exit(1) end

local function exec(sql)
  return conn:execute(sql)
end
-- PURGE: no copy in the recycle bin of the test user (LOB segments
-- included); IF EXISTS: no error if the table is not there (Oracle 23ai)
local function drop(name)
  return exec("DROP TABLE IF EXISTS " .. name .. " PURGE")
end
local function scalar(sql)
  local cur, e = exec(sql)
  if not cur or type(cur) ~= "userdata" then return nil, e end
  local v = cur:fetch()
  cur:close()
  return v
end

-- how the session is connected: protocol and, if the view may be read,
-- the negotiated encryption and integrity algorithms (information only)
info("network protocol",
  scalar("SELECT SYS_CONTEXT('USERENV', 'NETWORK_PROTOCOL') FROM dual"))
do
  local cur = exec([[SELECT network_service_banner FROM v$session_connect_info
                      WHERE sid = SYS_CONTEXT('USERENV', 'SID')]])
  if type(cur) == "userdata" then
    local enc, sum = "none", "none"
    local b = cur:fetch()
    while b do
      enc = b:match("^(%S+) Encryption service adapter") or enc
      sum = b:match("^(%S+) Crypto%-checksumming service adapter") or sum
      b = cur:fetch()
    end
    info("network encryption", enc)
    info("network integrity", sum)
  else
    info("network encryption", "unknown (no access to V$SESSION_CONNECT_INFO)")
  end
end

-- drop leftovers of an earlier run
drop(TABLE)

print("-- DDL and DML")
local r, e = exec("CREATE TABLE " .. TABLE ..
  " (id NUMBER(10) PRIMARY KEY, txt VARCHAR2(40 CHAR), num NUMBER(12,3), d DATE, ts TIMESTAMP)")
check("create table", r ~= nil, e)
r, e = exec("INSERT INTO " .. TABLE .. " VALUES (1, '" .. TXT .. "', 3.5, DATE '2026-10-17', " ..
  "TIMESTAMP '2026-10-17 12:34:56')")
check("insert returns 1", r == 1, e or r)
r, e = exec("UPDATE " .. TABLE .. " SET num = num + 1 WHERE id = 1")
check("update returns 1", r == 1, e or r)

print("-- query")
local cur
cur, e = exec("SELECT id, txt, num, d, ts FROM " .. TABLE .. " ORDER BY id")
check("select returns a cursor", type(cur) == "userdata", e)
if type(cur) == "userdata" then
  local names, types = cur:getcolnames(), cur:getcoltypes()
  check("column names", names[1] == "id" and names[2] == "txt" and names[5] == "ts",
        table.concat(names, ","))
  info("column types", table.concat(types, ","))
  local id, txt, num, d, ts = cur:fetch()
  check("id read back", tonumber(id) == 1, id)
  info("id lua type", math.type(id) or type(id))
  check("text read back with umlauts", txt == TXT, txt)
  check("number read back", tonumber(num) == 4.5, num)
  info("date as delivered", d)
  info("timestamp as delivered", ts)
  check("second fetch returns nil", cur:fetch() == nil)
  local fok = pcall(cur.fetch, cur)
  check("cursor is closed after the last row", not fok)
  pcall(cur.close, cur)
end
-- server side check: Lua round trips hide a wrong character set
check("server counts 5 characters (UTF-8 intact)",
      tonumber(scalar("SELECT LENGTH(txt) FROM " .. TABLE .. " WHERE id = 1")) == 5)

print("-- transactions")
check("setautocommit(false)", conn:setautocommit(false))
exec("INSERT INTO " .. TABLE .. " (id, txt) VALUES (2, 'rollback')")
conn:rollback()
check("rollback undoes the insert",
      tonumber(scalar("SELECT COUNT(*) FROM " .. TABLE)) == 1)
exec("INSERT INTO " .. TABLE .. " (id, txt) VALUES (3, 'commit')")
conn:commit()
check("commit keeps the insert",
      tonumber(scalar("SELECT COUNT(*) FROM " .. TABLE)) == 2)
conn:setautocommit(true)
-- a commit that violates a deferred constraint fails, and Oracle rolls
-- the transaction back
drop("lt_oci8_def")
exec("CREATE TABLE lt_oci8_def (id NUMBER CONSTRAINT lt_oci8_def_pk"
     .. " PRIMARY KEY DEFERRABLE INITIALLY DEFERRED)")
conn:setautocommit(false)
exec("INSERT INTO lt_oci8_def (id) VALUES (1)")
exec("INSERT INTO lt_oci8_def (id) VALUES (1)")
local cok, cerr = conn:commit()
check("failing commit returns false and a message",
      cok == false and tostring(cerr):find("ORA%-") ~= nil, tostring(cerr))
if cerr then info("failing commit", mask(cerr)) end
check("failing commit rolls back",
      tonumber(scalar("SELECT COUNT(*) FROM lt_oci8_def")) == 0)
conn:setautocommit(true)
drop("lt_oci8_def")

print("-- error path")
local c2, e2 = exec("SELECT * FROM lt_oci8_does_not_exist")
check("error returns nil and ORA-00942", c2 == nil and tostring(e2):find("ORA%-00942") ~= nil, e2)
if e2 then info("message", mask(e2)) end
-- an empty statement fails before the execute (OCIStmtPrepare); the
-- statement handle must be freed on that path, too
local c3, e3 = exec("")
check("empty statement returns nil and ORA-24373",
  c3 == nil and tostring(e3):find("ORA%-24373") ~= nil, e3)
local c4, e4 = conn:prepare("")
check("prepare of an empty statement returns nil and ORA-24373",
  c4 == nil and tostring(e4):find("ORA%-24373") ~= nil, e4)

print("-- unsupported column type")
local cu, eu = conn:execute("select bfilename('X', 'y') from dual")
check("unsupported type returns nil and message",
      cu == nil and tostring(eu):find("unsupported column type") ~= nil, eu)
collectgarbage()

local st = conn:prepare("select bfilename('X', 'y') from dual")
local cs, es = st:execute({})
check("prepared: unsupported type returns nil and message",
      cs == nil and tostring(es):find("unsupported column type") ~= nil, es)
check("statement closes after failed execute", st:close())

print("-- CLOB")
local function fetch1(sql)
  local fc, fe = conn:execute(sql)
  if not fc then return false, fe end
  local fv, fe2 = fc:fetch()
  fc:close()
  return fe2 == nil, fv, fe2
end

local parts, expect = {}, {}
for _ = 1, 10 do
  for _, ch in ipairs{"x", "ä", "ö", "ü", "ß"} do
    parts[#parts + 1] = "to_clob(rpad('" .. ch .. "', 1500, '" .. ch .. "'))"
    expect[#expect + 1] = string.rep(ch, 1500)
  end
end

local expr, exp = table.concat(parts, " || "), table.concat(expect)
do
  local _, len, lerr = fetch1("select dbms_lob.getlength(" .. expr .. ") from dual")
  print("  [INFO] server length (chars): " .. tostring(len or lerr))
end
local v
ok, v, e = fetch1("select " .. expr .. " from dual")
check("large CLOB with umlauts is read completely", ok and v == exp,
      e or (v and (#v .. " bytes, expected " .. #exp .. ": " .. (#v < 200 and v or v:sub(1, 60)))))
check("session usable after CLOB read", fetch1("select 1 from dual"))

ok, v, e = fetch1("select to_clob('abc') from dual")
check("short CLOB", ok and v == "abc", e)
ok, v, e = fetch1("select empty_clob() from dual")
check("empty CLOB gives empty string", ok and v == "", e)
ok, v, e = fetch1("select to_clob(null) from dual")
check("NULL CLOB gives nil", ok and v == nil, e)
ok, v, e = fetch1("select to_nclob('Grüße') from dual")
check("NCLOB", ok and v == "Grüße", e or v)
local cr, er = conn:execute("select to_clob('row ' || level) as c from dual connect by level <= 3")
local n, good = 0, cr ~= nil
while cr do
  local row = cr:fetch({}, "na")
  if not row then break end
  n = n + 1
  good = good and row[1] == "row " .. n and row.c == row[1]
end
check("temporary CLOBs over several rows, read twice per row", good and n == 3, er or n)

-- surrogate pairs across a chunk boundary (LOB_CHUNK_CHARS = 16384 UTF-16 units)
local EMO = "\u{1F600}"   -- 1 character, 2 UTF-16 units, 4 bytes in UTF-8
for _, f in ipairs{ "to_clob", "to_nclob" } do
  for _, lead in ipairs{ "", "a" } do
    local p = {}
    if lead ~= "" then p[1] = f .. "('" .. lead .. "')" end
    for _ = 1, 10 do p[#p + 1] = f .. "('" .. EMO:rep(900) .. "')" end
    local want = lead .. EMO:rep(9000)
    ok, v, e = fetch1("select " .. table.concat(p, " || ") .. " from dual")
    check(string.format("%s: 9000 emojis%s across a chunk boundary", f,
          lead ~= "" and " after 'a' (pair split at 16384)" or ""),
          ok and v == want, e or (v and (#v .. " bytes, expected " .. #want)))
  end
end

print("-- BOOLEAN")
ok, v, e = fetch1("select true from dual")
check("BOOLEAN true", ok and v == true, e or tostring(v))
ok, v, e = fetch1("select false from dual")
check("BOOLEAN false", ok and v == false, e or tostring(v))
ok, v, e = fetch1("select cast(null as boolean) from dual")
check("BOOLEAN NULL gives nil", ok and v == nil, e or tostring(v))
local cb, eb = conn:execute("select true from dual")
local tb = cb and cb:getcoltypes()[1]
check("BOOLEAN column type", tb == "boolean", eb or tb)
if cb then cb:close() end

print("-- BINARY_FLOAT / BINARY_DOUBLE")
local function fdesc(x) return tostring(x) .. " (" .. tostring(math.type(x)) .. ")" end
local F01 = string.unpack("f", string.pack("f", 0.1))   -- 0.1 rounded to float32
local bcases = {
   { "1.5f", 1.5 },
   { "0.1f", F01 },
   { "0.1d", 0.1 },
   { "0.1d + 0.2d", 0.1 + 0.2 },
   { "1e300d", 1e300 },
   { "binary_double_infinity", math.huge },
   { "-binary_double_infinity", -math.huge },
}
for _, c in ipairs(bcases) do
   ok, v, e = fetch1("select " .. c[1] .. " from dual")
   check("binary: " .. c[1], ok and v == c[2] and math.type(v) == "float", e or fdesc(v))
end
ok, v, e = fetch1("select binary_double_nan from dual")
check("binary: NaN", ok and v ~= v, e or fdesc(v))
ok, v, e = fetch1("select cast(null as binary_double) from dual")
check("binary: NULL gives nil", ok and v == nil, e)
local cbt = conn:execute("select 1f, 1d from dual")
local tbt = cbt and table.concat(cbt:getcoltypes(), ",")
check("BINARY_FLOAT/DOUBLE column types", tbt == "number,number", tbt)
if cbt then cbt:close() end
conn:setoption("numbers", "exact")
ok, v, e = fetch1("select 42d from dual")
check("binary: stays float in exact mode", ok and v == 42 and math.type(v) == "float", e or fdesc(v))
conn:setoption("numbers", "float")

print("-- strings")
ok, v, e = fetch1("select 'ab' || chr(0) || 'cd' from dual")
check("embedded zero is kept", ok and v == "ab\0cd", e or (v and #v .. " bytes"))
ok, v, e = fetch1("select 'abc  ' from dual")
check("trailing blanks are kept", ok and v == "abc  ", e or (v and "'" .. v .. "'"))
ok, v, e = fetch1("select cast('abc' as char(5)) from dual")
check("CHAR(5) stays blank-padded", ok and v == "abc  ", e or (v and "'" .. v .. "'"))
ok, v, e = fetch1("select 'Grüße' from dual")
check("umlauts in VARCHAR2", ok and v == "Grüße", e or v)

print("-- NCHAR / NVARCHAR2")
local EURO5 = string.rep("\u{20AC}", 5)   -- 5 characters, 15 bytes in UTF-8
local U_EURO5 = "unistr('" .. string.rep("\\20AC", 5) .. "')"
ok, v, e = fetch1("select cast(" .. U_EURO5 .. " as nchar(5)) from dual")
check("NCHAR(5) with 5 euro signs", ok and v == EURO5, e or (v and #v .. " bytes"))
ok, v, e = fetch1("select cast(" .. U_EURO5 .. " as nvarchar2(5)) from dual")
check("NVARCHAR2(5) with 5 euro signs", ok and v == EURO5, e or (v and #v .. " bytes"))
ok, v, e = fetch1("select cast(unistr('ab') as nchar(5)) from dual")
check("NCHAR(5) stays blank-padded", ok and v == "ab   ", e or (v and "'" .. v .. "'"))
ok, v, e = fetch1("select cast(unistr('Gr\\00FC\\00DFe') as nvarchar2(10)) from dual")
check("NVARCHAR2 with umlauts", ok and v == "Gr\u{FC}\u{DF}e", e or v)
ok, v, e = fetch1("select unistr('\\D83D\\DE00') from dual")
check("NVARCHAR2 outside the BMP (emoji)", ok and v == "\u{1F600}", e or (v and #v .. " bytes"))
local cn = conn:execute("select cast('x' as nchar(1)), cast('x' as nvarchar2(1)) from dual")
local tn = cn and table.concat(cn:getcoltypes(), ",")
check("NCHAR/NVARCHAR2 column types", tn == "string,string", tn)
if cn then cn:close() end

print("-- ROWID / UROWID")
ok, v, e = fetch1("select rowid from " .. TABLE .. " where id = 1")
check("ROWID as 18-character string", ok and type(v) == "string" and #v == 18, e or tostring(v))
local rid = v
ok, v, e = fetch1("select id from " .. TABLE .. " where rowid = '" .. tostring(rid) .. "'")
check("ROWID string finds the row again", ok and tonumber(v) == 1, e or tostring(v))
ok, v, e = fetch1("select cast(rowid as urowid) from " .. TABLE .. " where id = 1")
check("UROWID of a heap row equals its ROWID", ok and v == rid, e or tostring(v))
drop("lt_oci8_iot")
exec("CREATE TABLE lt_oci8_iot (id NUMBER PRIMARY KEY) ORGANIZATION INDEX")
exec("INSERT INTO lt_oci8_iot VALUES (7)")
ok, v, e = fetch1("select rowid from lt_oci8_iot")
check("logical rowid of an index-organized table", ok and type(v) == "string" and v:sub(1, 1) == "*", e or tostring(v))
local lrid = v
ok, v, e = fetch1("select id from lt_oci8_iot where rowid = '" .. tostring(lrid) .. "'")
check("logical rowid finds the row again", ok and tonumber(v) == 7, e or tostring(v))
drop("lt_oci8_iot")
local crt = conn:execute("select rowid, cast(rowid as urowid) from " .. TABLE .. " where id = 1")
local trt = crt and table.concat(crt:getcoltypes(), ",")
check("ROWID/UROWID column types", trt == "string,string", trt)
if crt then crt:close() end

print("-- RAW")
local function hex(s) return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end)) end
ok, v, e = fetch1("select hextoraw('00FF4100') from dual")
check("RAW with zero bytes", ok and v == "\0\255A\0", e or (v and hex(v)))
ok, v, e = fetch1("select sys_guid() from dual")
check("RAW(16) from SYS_GUID", ok and type(v) == "string" and #v == 16, e or (v and #v .. " bytes"))
ok, v, e = fetch1("select utl_raw.copies(hextoraw('DEADBEEF'), 500) from dual")
check("RAW with 2000 bytes", ok and v == string.rep("\222\173\190\239", 500), e or (v and #v .. " bytes"))
ok, v, e = fetch1("select hextoraw('') from dual")
check("empty RAW gives nil (Oracle: NULL)", ok and v == nil, e or (v and hex(v)))
local cw = conn:execute("select hextoraw('41') from dual")
local tw = cw and cw:getcoltypes()[1]
check("RAW column type", tw == "binary", tw)
if cw then cw:close() end

print("-- BLOB")
ok, v, e = fetch1("select to_blob(hextoraw('00FF4100')) from dual")
check("short BLOB with zero bytes", ok and v == "\0\255A\0", e or (v and hex(v)))
ok, v, e = fetch1("select empty_blob() from dual")
check("empty BLOB gives empty string", ok and v == "", e or (v and hex(v)))
local function what(x) return type(x) == "string" and (#x .. " bytes") or tostring(x) end
ok, v, e = fetch1("select to_blob(null) from dual")
check("NULL BLOB (to_blob) gives nil", ok and v == nil, e or what(v))
drop("lt_oci8_blob")
exec("CREATE TABLE lt_oci8_blob (id NUMBER PRIMARY KEY, b BLOB)")
exec("INSERT INTO lt_oci8_blob VALUES (1, EMPTY_BLOB())")
exec("INSERT INTO lt_oci8_blob VALUES (2, NULL)")
ok, v, e = fetch1("select b from lt_oci8_blob where id = 2")
check("NULL BLOB from a table column gives nil", ok and v == nil, e or what(v))
r, e = exec([[
DECLARE
  v BLOB;
BEGIN
  SELECT b INTO v FROM lt_oci8_blob WHERE id = 1 FOR UPDATE;
  DBMS_LOB.APPEND(v, TO_BLOB(UTL_RAW.COPIES(HEXTORAW('AA'), 30000)));
  DBMS_LOB.APPEND(v, TO_BLOB(UTL_RAW.COPIES(HEXTORAW('BB'), 30000)));
  DBMS_LOB.APPEND(v, TO_BLOB(UTL_RAW.COPIES(HEXTORAW('CC'), 30000)));
END;]])
check("PL/SQL fills a BLOB with 90000 bytes", r ~= nil, e)
local BIG = string.rep("\170", 30000) .. string.rep("\187", 30000) .. string.rep("\204", 30000)
ok, v, e = fetch1("select b from lt_oci8_blob where id = 1")
check("BLOB with 90000 bytes over several chunks", ok and v == BIG, e or (v and #v .. " bytes"))
drop("lt_oci8_blob")
local cbr, ebr = conn:execute("select to_blob(hextoraw('0' || level)) as b from dual connect by level <= 3")
local nb, goodb = 0, cbr ~= nil
while cbr do
  local row = cbr:fetch({}, "na")
  if not row then break end
  nb = nb + 1
  goodb = goodb and row[1] == string.char(nb) and row.b == row[1]
end
check("temporary BLOBs over several rows, read twice per row", goodb and nb == 3, ebr or nb)
local cbt2 = conn:execute("select empty_blob() from dual")
local tbt2 = cbt2 and cbt2:getcoltypes()[1]
check("BLOB column type", tbt2 == "binary", tbt2)
if cbt2 then cbt2:close() end

print("-- INTERVAL")
-- expected texts as shown by SQL*Plus and TO_CHAR
local icases = {
  { "interval '1-2' year to month", "+01-02" },
  { "interval '-1-2' year to month", "-01-02" },
  { "interval '123-11' year(3) to month", "+123-11" },
  { "interval '1 02:03:04.5' day to second", "+01 02:03:04.500000" },
  { "interval '-0 00:00:00.000001' day to second", "-00 00:00:00.000001" },
  { "interval '12345 0:0:0' day(5) to second(0)", "+12345 00:00:00" },
  { "timestamp '2026-10-24 12:00:00' - timestamp '2026-10-23 10:30:15.25'",
    "+000000001 01:29:44.750000000" },
  { "numtodsinterval(1.5, 'DAY')", "+000000001 12:00:00.000000000" },
  { "numtoyminterval(14, 'MONTH')", "+000000001-02" },
}
for _, c in ipairs(icases) do
  ok, v, e = fetch1("select " .. c[1] .. " from dual")
  check("interval: " .. c[1], ok and v == c[2], e or ("'" .. tostring(v) .. "'"))
end
ok, v, e = fetch1("select cast(null as interval day to second) from dual")
check("interval: NULL gives nil", ok and v == nil, e or tostring(v))
drop("lt_oci8_iv")
exec("CREATE TABLE lt_oci8_iv (ym INTERVAL YEAR(4) TO MONTH, ds INTERVAL DAY(3) TO SECOND(2))")
exec("INSERT INTO lt_oci8_iv VALUES (INTERVAL '12-3' YEAR(4) TO MONTH, " ..
  "INTERVAL '4 05:06:07.89' DAY(3) TO SECOND(2))")
local civ, eiv = conn:execute("select ym, ds from lt_oci8_iv")
local ym, ds
if civ then ym, ds = civ:fetch(); civ:close() end
check("interval column YEAR(4) TO MONTH", ym == "+0012-03", eiv or ("'" .. tostring(ym) .. "'"))
check("interval column DAY(3) TO SECOND(2)", ds == "+004 05:06:07.89", eiv or ("'" .. tostring(ds) .. "'"))
drop("lt_oci8_iv")
-- the text goes back in via TO_DSINTERVAL / TO_YMINTERVAL
local function back(sql, fn, lit)
  local bok, bv, be = fetch1(sql)
  if not bok or type(bv) ~= "string" then return false, nil, be or tostring(bv) end
  return fetch1("select case when " .. fn .. "('" .. bv .. "') = " .. lit ..
                " then 1 else 0 end from dual")
end
ok, v, e = back("select timestamp '2026-10-24 12:00:00' - timestamp '2026-10-23 10:30:15.25' from dual",
  "to_dsinterval", "interval '1 01:29:44.75' day to second")
check("interval text goes back via TO_DSINTERVAL", ok and tonumber(v) == 1, e or tostring(v))
ok, v, e = back("select numtoyminterval(14, 'MONTH') from dual",
  "to_yminterval", "interval '1-2' year to month")
check("interval text goes back via TO_YMINTERVAL", ok and tonumber(v) == 1, e or tostring(v))
local ci = conn:execute("select interval '1-2' year to month, interval '1' day from dual")
local ti = ci and table.concat(ci:getcoltypes(), ",")
check("INTERVAL column types", ti == "interval,interval", ti)
if ci then ci:close() end

print("-- string binds")
local T = luasql.type  -- same source as 't' in dataTypes.lua
local function bind1(val)
   local s, se = conn:prepare("select :1 from dual")
   if not s then return false, nil, se end
   local c, ce = s:execute({ { val, T.string } })
   if not c then s:close(); return false, nil, ce end
   local bv, be = c:fetch()
   c:close(); s:close()
   return be == nil, bv, be
end
ok, v, e = bind1("ab\0cd")
check("bind: embedded zero is kept", ok and v == "ab\0cd", e or (v and #v .. " bytes"))
ok, v, e = bind1("abc  ")
check("bind: trailing blanks are kept", ok and v == "abc  ", e or (v and "'" .. v .. "'"))
ok, v, e = bind1("Grüße")
check("bind: umlauts", ok and v == "Grüße", e or v)

print("-- string binds into CLOB/NCLOB columns")
drop("lt_oci8_cb")
exec("CREATE TABLE lt_oci8_cb (id NUMBER PRIMARY KEY, c CLOB, n NCLOB)")
local function putclob(id, col, val)
  local s, se = conn:prepare("INSERT INTO lt_oci8_cb (id, " .. col .. ") VALUES (:1, :2)")
  if not s then return nil, se end
  local pr, pe = s:execute({ { id, T.int }, { val, T.string } })
  s:close()
  return pr, pe
end
local cbcases = {
  { 1, "c", string.rep("x", 4000) },
  { 2, "c", string.rep("x", 4001) },
  { 3, "c", string.rep("x", 32767) },
  { 4, "c", string.rep("x", 32768) },
  { 5, "c", string.rep("x", 100000) },
  { 6, "c", string.rep("\u{E4}", 50000) },   -- 50000 characters, 100000 bytes
  { 7, "n", string.rep("\u{E4}", 50000) },
}
for _, c in ipairs(cbcases) do
  local id, col, val = c[1], c[2], c[3]
  local pr, pe = putclob(id, col, val)
  local okr, vr, rerr = fetch1("select " .. col .. " from lt_oci8_cb where id = " .. id)
  check(string.format("bind string of %d bytes%s into %s", #val,
		      val:find("\u{E4}", 1, true) and " (umlauts)" or "",
		      col == "c" and "CLOB" or "NCLOB"),
        pr == 1 and okr and vr == val,
        pe or rerr or (vr and (#vr .. " bytes read back")) or "nothing read back")
end
drop("lt_oci8_cb")

print("-- options")
check("numbers defaults to float", conn:getoption("numbers") == "float")
check("setoption numbers=exact", conn:setoption("numbers", "exact") == true)
check("getoption reflects change", conn:getoption("numbers") == "exact")
local r1, m1 = pcall(conn.setoption, conn, "numbers", "bogus")
check("invalid value raises an error", not r1 and tostring(m1):find("invalid value") ~= nil, m1)
check("invalid value keeps mode", conn:getoption("numbers") == "exact")
local r2, m2 = pcall(conn.setoption, conn, "bogus", "x")
check("unknown option raises an error", not r2 and tostring(m2):find("unknown option") ~= nil, m2)
local r3, m3 = pcall(conn.getoption, conn, "bogus")
check("getoption: unknown option raises an error", not r3 and tostring(m3):find("unknown option") ~= nil, m3)
check("back to float", conn:setoption("numbers", "float") == true and conn:getoption("numbers") == "float")

print("-- prefetch")
check("prefetch defaults to 100", conn:getoption("prefetch") == 100)
check("prefetch is an integer", math.type(conn:getoption("prefetch")) == "integer")
for _, bad in ipairs{ -1, 1.5, 2^31, "100", 0/0 } do
  local pr, pm = pcall(conn.setoption, conn, "prefetch", bad)
  check("prefetch rejects " .. type(bad) .. " " .. tostring(bad),
    not pr and tostring(pm):find("invalid value") ~= nil, pm)
end
check("invalid prefetch keeps the value", conn:getoption("prefetch") == 100)
-- the largest value OCI accepts (MINSWORDMAXVAL); only set, not used
check("prefetch accepts 2147483647",
  conn:setoption("prefetch", 2147483647) == true and conn:getoption("prefetch") == 2147483647)
-- every value reads every row exactly once, by execute and by prepared
drop("lt_oci8_pf")
assert(exec("CREATE TABLE lt_oci8_pf (id NUMBER)"))
assert(exec("INSERT INTO lt_oci8_pf SELECT level FROM dual CONNECT BY level <= 250"))
local function ids(c)
  if type(c) ~= "userdata" then return -1, -1 end
  local count, total = 0, 0
  local id = c:fetch()
  while id do
    count, total = count + 1, total + id
    id = c:fetch()
  end
  return count, total
end
local pfstmt = assert(conn:prepare("SELECT id FROM lt_oci8_pf WHERE id <= :1 ORDER BY id"))
for _, pf in ipairs{ 0, 1, 7, 100, 1000 } do
  check("setoption prefetch=" .. pf,
    conn:setoption("prefetch", pf) == true and conn:getoption("prefetch") == pf)
  local rows, sum = ids(exec("SELECT id FROM lt_oci8_pf ORDER BY id"))
  check("prefetch " .. pf .. ": execute reads 250 rows", rows == 250 and sum == 31375,
    rows .. " rows, sum " .. sum)
  rows, sum = ids(pfstmt:execute{ {250, T.int} })
  check("prefetch " .. pf .. ": prepared reads 250 rows", rows == 250 and sum == 31375,
    rows .. " rows, sum " .. sum)
end
check("back to 100", conn:setoption("prefetch", 100) == true)
local pfcur = exec("SELECT id FROM lt_oci8_pf ORDER BY id")
check("prefetched cursor closed after its first row",
  type(pfcur) == "userdata" and pfcur:fetch() == 1 and pfcur:close() == true)
pfcur = pfstmt:execute{ {250, T.int} }
check("prepared: prefetched cursor closed after its first row",
  type(pfcur) == "userdata" and pfcur:fetch() == 1 and pfcur:close() == true)
local pfrows = ids(pfstmt:execute{ {10, T.int} })
check("statement usable after an early close", pfrows == 10, pfrows)
pfstmt:close()
drop("lt_oci8_pf")

print("-- numbers = exact")
local function num1(ex) return fetch1("select " .. ex .. " from dual") end
local function desc(x) return tostring(x) .. " (" .. tostring(math.type(x)) .. ")" end
check("setoption numbers=exact", conn:setoption("numbers", "exact") == true)
local cases = {
  { "42", 42, "integer" },
  { "-7", -7, "integer" },
  { "0", 0, "integer" },
  { "count(*)", 1, "integer" },
  { "9007199254740993", 9007199254740993, "integer" },
  { "9223372036854775807", math.maxinteger, "integer" },
  { "-9223372036854775808", math.mininteger, "integer" },
  { "1e30", 1e30, "float" },
  { "1.5", 1.5, "float" },
  { "-0.25", -0.25, "float" },
  { "1e-100", 1e-100, "float" },
  { "1.5e100", 1.5e100, "float" },
}
for _, c in ipairs(cases) do
  ok, v, e = num1(c[1])
  check("exact: " .. c[1], ok and v == c[2] and math.type(v) == c[3], e or desc(v))
end
ok, v, e = num1("cast(null as number)")
check("exact: NULL gives nil", ok and v == nil, e)
conn:execute("alter session set nls_numeric_characters = ',.'")
ok, v, e = num1("1.5")
check("exact: 1.5 with decimal comma session", ok and v == 1.5, e or desc(v))
conn:execute("alter session set nls_numeric_characters = '.,'")
check("back to float", conn:setoption("numbers", "float") == true)
ok, v, e = num1("42")
check("float: 42 stays float (legacy)", ok and v == 42 and math.type(v) == "float", e or desc(v))

print("-- JSON")
local JSRC = '{"a":1,"b":[true,null,"x"]}'
ok, v, e = fetch1("select json('" .. JSRC .. "') from dual")
check("JSON as compact text", ok and v == JSRC, e or tostring(v))
ok, v, e = fetch1([[select json('{"k":"Grüße"}') from dual]])
check("JSON with umlauts", ok and v == '{"k":"Grüße"}', e or tostring(v))
ok, v, e = fetch1("select json(null) from dual")
check("JSON NULL gives nil", ok and v == nil, e or tostring(v))
-- larger than one LOB chunk (16384 characters)
local jparts = { "to_clob('{\"s\":\"')" }
for _ = 1, 10 do jparts[#jparts + 1] = "to_clob(rpad('x', 4000, 'x'))" end
jparts[#jparts + 1] = "to_clob('\"}')"
ok, v, e = fetch1("select json(" .. table.concat(jparts, " || ") .. ") from dual")
check("JSON larger than one LOB chunk", ok and v == '{"s":"' .. string.rep("x", 40000) .. '"}',
      e or (v and #v .. " bytes"))
-- JSON column, written by a string bind
drop("lt_oci8_js")
exec("CREATE TABLE lt_oci8_js (id NUMBER PRIMARY KEY, j JSON)")
local stj, esj = conn:prepare("INSERT INTO lt_oci8_js VALUES (1, :1)")
local rj, ejw
if stj then rj, ejw = stj:execute({ { JSRC, T.string } }); stj:close() end
check("JSON column written by a string bind", rj == 1, esj or ejw)
ok, v, e = fetch1("select j from lt_oci8_js where id = 1")
check("JSON column read back", ok and v == JSRC, e or tostring(v))
local jread = v
local cjs = conn:execute("select j from lt_oci8_js")
local tjs = cjs and cjs:getcoltypes()[1]
check("JSON column type", tjs == "json", tjs)
if cjs then cjs:close() end
drop("lt_oci8_js")
-- decoding is the application's job, e.g. with lua-cjson or dkjson
local okc, cjson = pcall(require, "cjson")
if okc and type(jread) == "string" then
   local d = cjson.decode(jread)
   check("cjson decodes the JSON text",
	 d.a == 1 and d.b[1] == true and d.b[2] == cjson.null and d.b[3] == "x")
else
   info("cjson", "not available, decode check skipped")
end

print("-- DATE / TIMESTAMP")
local function bindv(val, typ)
   local s, se = conn:prepare("select :1 from dual")
   if not s then return false, nil, se end
   local c, ce = s:execute({ { val, typ } })
   if not c then s:close(); return false, nil, ce end
   local bv, be = c:fetch()
   c:close(); s:close()
   return be == nil, bv, be
end
local dcases = {
   { "date '2026-10-24'", "2026-10-24 00:00:00" },
   { "date '0001-01-01'", "0001-01-01 00:00:00" },
   { "date '-4712-01-01'", "-4712-01-01 00:00:00" },
   { "to_date('-0044-03-15 12:00:00', 'SYYYY-MM-DD HH24:MI:SS')", "-0044-03-15 12:00:00" },
   { "timestamp '2026-10-24 12:00:00.5'", "2026-10-24 12:00:00.500000" },
   { "to_timestamp('-0044-03-15 12:00:00.5', 'SYYYY-MM-DD HH24:MI:SS.FF')",
     "-0044-03-15 12:00:00.500000" },
   { "to_timestamp_tz('-0044-03-15 12:00:00 +01:00', 'SYYYY-MM-DD HH24:MI:SS TZH:TZM')",
     "-0044-03-15 12:00:00.000000 +01:00" },
}
for _, c in ipairs(dcases) do
   ok, v, e = fetch1("select " .. c[1] .. " from dual")
   check("read: " .. c[1], ok and v == c[2], e or ("'" .. tostring(v) .. "'"))
end
check("luasql.type has date and timestamp", T.date ~= nil and T.timestamp ~= nil)
local dbcases = {
   { "2026-10-24", "date", "2026-10-24 00:00:00" },
   { "2026-10-24 12:34:56", "date", "2026-10-24 12:34:56" },
   { "-4712-01-01", "date", "-4712-01-01 00:00:00" },
   { "2026-10-24 12:00:00", "timestamp", "2026-10-24 12:00:00.000000" },
   { "2026-10-24 12:00:00.5", "timestamp", "2026-10-24 12:00:00.500000" },
   { "-0044-03-15 12:00:00.500000", "timestamp", "-0044-03-15 12:00:00.500000" },
}
for _, c in ipairs(dbcases) do
   ok, v, e = bindv(c[1], T[c[2]])
   check("bind " .. c[2] .. ": " .. c[1], ok and v == c[3], e or ("'" .. tostring(v) .. "'"))
end
-- what was read goes back in unchanged
for _, sql in ipairs({ "date '-4712-01-01'", "timestamp '2026-10-24 12:00:00.123456'" }) do
   local okr, vr, rerr = fetch1("select " .. sql .. " from dual")
   local typ = sql:match("^%a+")
   local okb, vb, berr = false, nil, rerr
   if okr then okb, vb, berr = bindv(vr, T[typ]) end
   check("read value binds back: " .. sql, okb and vb == vr, berr or ("'" .. tostring(vb) .. "'"))
end
ok, v, e = bindv("24.10.2026", T.date)
check("bind date: wrong format gives an error", not ok and v == nil and e ~= nil, e or tostring(v))
info("wrong date format message", e)

print("-- NaN / infinity binds")
drop("lt_oci8_nan")
exec("CREATE TABLE lt_oci8_nan (id NUMBER, n NUMBER, bd BINARY_DOUBLE)")
local function ins(col, id, val)
   local s, se = conn:prepare("INSERT INTO lt_oci8_nan (id, " .. col .. ") VALUES (:1, :2)")
   if not s then return nil, se end
   local ir, ie = s:execute({ { id, T.number }, { val, T.number } })
   s:close()
   return ir, ie
end
local inf = math.huge
local n1, ne1 = ins("n", 1, 0/0)
check("NaN into NUMBER fails", n1 == nil and tostring(ne1):find("ORA%-03087") ~= nil, ne1 or n1)
local n2, ne2 = ins("n", 2, inf)
check("inf into NUMBER fails", n2 == nil and tostring(ne2):find("ORA%-01426") ~= nil, ne2 or n2)
local n3, ne3 = ins("n", 3, -inf)
check("-inf into NUMBER fails", n3 == nil and tostring(ne3):find("ORA%-01426") ~= nil, ne3 or n3)
check("NaN into BINARY_DOUBLE", ins("bd", 4, 0/0) == 1)
check("inf into BINARY_DOUBLE", ins("bd", 5, inf) == 1)
check("-inf into BINARY_DOUBLE", ins("bd", 6, -inf) == 1)
check("finite value into NUMBER", ins("n", 7, 2.5) == 1)
local cnan, enan = conn:execute("SELECT id, n, bd FROM lt_oci8_nan ORDER BY id")
local got = {}
while cnan do
   local id, nv, bd = cnan:fetch()
   if not id then break end
   got[math.tointeger(id) or id] = { n = nv, bd = bd }
end
if cnan then cnan:close() end
check("no row from the failed NUMBER inserts", got[1] == nil and got[2] == nil and got[3] == nil, enan)
check("NaN read back from BINARY_DOUBLE", got[4] and got[4].bd ~= got[4].bd, got[4] and tostring(got[4].bd))
check("inf read back from BINARY_DOUBLE", got[5] and got[5].bd == inf, got[5] and tostring(got[5].bd))
check("-inf read back from BINARY_DOUBLE", got[6] and got[6].bd == -inf, got[6] and tostring(got[6].bd))
check("finite NUMBER still read back", got[7] and got[7].n == 2.5, got[7] and tostring(got[7].n))
drop("lt_oci8_nan")

print("-- stmt:execute() without parameters")
local sp = conn:prepare("select 42 from dual")
local cp, ep, vp
if sp then cp, ep = sp:execute() end
vp = cp and cp:fetch()
if cp then cp:close() end
check("execute() runs a statement without placeholders", tonumber(vp) == 42, ep or tostring(vp))
if sp then cp, ep = sp:execute(nil) end
check("execute(nil) is one parameter: nil, msg without placeholders",
      cp == nil and tostring(ep):find("statement has 0 parameters, 1 given", 1, true) ~= nil,
      tostring(ep))
if sp then cp, ep = sp:execute() end
vp = cp and cp:fetch()
if cp then cp:close() end
check("execute() again on the same statement", tonumber(vp) == 42, ep or tostring(vp))
if sp then sp:close() end
local sq = conn:prepare("select :1 from dual")
local cq, eq
if sq then cq, eq = sq:execute() end
if cq then cq:close() end
check("execute() with a placeholder gives ORA-01008",
      cq == nil and tostring(eq):find("ORA%-01008") ~= nil, eq or tostring(cq))
if sq then sq:close() end

print("-- bindings stay on the statement, stmt:reset()")
-- runs stmt:execute(...) and returns ok, first row values or the error
local function run(s, ...)
   local c, re = s:execute(...)
   if type(c) ~= "userdata" then return false, re end
   local a, b = c:fetch()
   c:close()
   return true, a, b
end
local ok1, a1, b1, e1
local s1 = assert(conn:prepare("select cast(:1 as number) from dual"))
ok1, a1 = run(s1, { { 42, T.int } })
check("bind 42", ok1 and tonumber(a1) == 42, tostring(a1))
for i = 1, 3 do
   collectgarbage("collect")
   ok1, a1 = run(s1)
   check("execute() repeats 42 (" .. i .. ")", ok1 and tonumber(a1) == 42, tostring(a1))
end
ok1, a1 = run(s1, {})
check("execute({}) repeats 42", ok1 and tonumber(a1) == 42, tostring(a1))
ok1, a1 = run(s1, { { 7, T.int } })
check("new value replaces the old one", ok1 and tonumber(a1) == 7, tostring(a1))
check("reset returns true", s1:reset() == true)
ok1, e1 = run(s1)
check("after reset: ORA-01008", not ok1 and tostring(e1):find("ORA%-01008") ~= nil, tostring(e1))
ok1, a1 = run(s1, { { 9, T.int } })
check("after reset: binding works again", ok1 and tonumber(a1) == 9, tostring(a1))
s1:close()

local s2 = assert(conn:prepare("select cast(:1 as number), cast(:2 as number) from dual"))
ok1, a1, b1 = run(s2, { { 1, T.int }, { 2, T.int } })
check("two values", ok1 and tonumber(a1) == 1 and tonumber(b1) == 2, tostring(a1) .. ", " .. tostring(b1))
ok1, a1, b1 = run(s2, { { 3, T.int } })
check("only :1 given: :2 keeps 2 (OCI)", ok1 and tonumber(a1) == 3 and tonumber(b1) == 2,
      tostring(a1) .. ", " .. tostring(b1))
s2:close()

-- the string is referenced only by the parameter table, which is
-- garbage after the call
local s3 = assert(conn:prepare("select length(:1) from dual"))
ok1, a1 = run(s3, { { string.rep("x\u{E4}", 1000), T.string } })
check("string bind", ok1 and tonumber(a1) == 2000, tostring(a1))
for _ = 1, 3 do collectgarbage("collect") end
ok1, a1 = run(s3)
check("string kept after garbage collection", ok1 and tonumber(a1) == 2000, tostring(a1))
s3:close()

local s4 = assert(conn:prepare("select :1 from dual"))
ok1, a1 = run(s4, { { "2026-10-24 12:00:00.5", T.timestamp } })
check("timestamp bind", ok1 and a1 == "2026-10-24 12:00:00.500000", tostring(a1))
collectgarbage("collect")
ok1, a1 = run(s4)
check("timestamp kept", ok1 and a1 == "2026-10-24 12:00:00.500000", tostring(a1))
ok1, a1 = run(s4, { { "2026-10-25 01:02:03", T.timestamp } })
check("timestamp rebound", ok1 and a1 == "2026-10-25 01:02:03.000000", tostring(a1))
check("reset with timestamp", s4:reset() == true)
s4:close()

local s5 = assert(conn:prepare("select cast(:a as number) from dual"))
ok1, a1 = run(s5, { a = { 5, T.int } })
check("named bind", ok1 and tonumber(a1) == 5, tostring(a1))
ok1, a1 = run(s5)
check("named binding kept", ok1 and tonumber(a1) == 5, tostring(a1))
s5:close()

local s6 = assert(conn:prepare("select cast(:1 as number) from dual"))
ok1, e1 = run(s6, { { 5, T.int }, { 6, T.int } })
check("too many parameters: ORA-01036", not ok1 and tostring(e1):find("ORA%-01036") ~= nil, tostring(e1))
ok1, a1 = run(s6, { { 7, T.int } })
check("statement usable after ORA-01036", ok1 and tonumber(a1) == 7, tostring(a1))
s6:close()

local s7 = assert(conn:prepare("select 1 from dual"))
check("reset without bindings", s7:reset() == true)
local c7 = s7:execute()
local r7, e7 = pcall(s7.reset, s7)
check("reset with open cursor raises an error",
      not r7 and tostring(e7):find("open cursor") ~= nil, tostring(e7))
r7, e7 = pcall(s7.execute, s7)
check("execute with open cursor raises an error",
      not r7 and tostring(e7):find("cursor still open") ~= nil, tostring(e7))
r7, e7 = s7:close()
check("close with open cursor returns false",
      r7 == false and tostring(e7):find("open cursor") ~= nil, tostring(e7))
if c7 then c7:close() end
check("close after the cursor is closed", s7:close() == true)
r7, e7 = s7:close()
check("close twice returns false", r7 == false and e7 ~= nil, tostring(e7))

print("-- invalid parameters raise an error before binding")
local s8 = assert(conn:prepare("select cast(:a as number) from dual"))
local bad_params = {
   { "mixed keys", { a = { 1, T.int }, [1] = { 2, T.int } }, "cannot mix" },
   { "wrong type", { a = { "x", T.int } }, "does not match" },
   { "unknown type constant", { a = { 1, 999 } }, "unknown luasql.type constant" },
   { "a function as value", { a = print }, "a function cannot be bound" },
   { "a table that is not a pair", { a = { 1, 2, 3 } }, "parameter must be a value or" },
   { "a float as T.int", { a = { 3.7, T.int } }, "does not match" },
}
for _, b in ipairs(bad_params) do
   r7, e7 = pcall(s8.execute, s8, b[2])
   check("execute: " .. b[1] .. " raises an error",
         not r7 and tostring(e7):find(b[3], 1, true) ~= nil, tostring(e7))
end
ok1, a1 = run(s8, { a = { 5, T.int } })
check("statement usable after the errors", ok1 and tonumber(a1) == 5, tostring(a1))
s8:close()

print("-- plain values and T.null")
check("T.null is not a number", type(T.null) == "userdata", type(T.null))
check("T.binary is a type constant", math.type(T.binary) == "integer")
drop("lt_oci8_pv")
exec("CREATE TABLE lt_oci8_pv (id NUMBER, n NUMBER, f BINARY_DOUBLE,"
     .. " s VARCHAR2(20), b BOOLEAN, z VARCHAR2(5))")
local spv = assert(conn:prepare("INSERT INTO lt_oci8_pv VALUES (:1, :2, :3, :4, :5, :6)"))
local rpv, epv = spv:execute(1, 9007199254740993, 0.1, TXT, true, nil)
check("variable arguments of all Lua types", rpv == 1, epv)
rpv, epv = spv:execute{ 2, -7, 1.5, "", false, T.null }
check("table of plain values", rpv == 1, epv)
spv:close()
conn:setoption("numbers", "exact")
do
   local cpv = assert(exec("SELECT n, f, s, b, z FROM lt_oci8_pv ORDER BY id"))
   local num, f, s, b, z = cpv:fetch()
   check("integer above 2^53 is exact", num == 9007199254740993 and math.type(num) == "integer",
         tostring(num))
   check("float as double", f == 0.1, tostring(f))
   check("string as text", s == TXT, tostring(s))
   check("true as TRUE", b == true, tostring(b))
   check("nil as variable argument is NULL", z == nil, tostring(z))
   num, f, s, b, z = cpv:fetch()
   check("second row: -7, 1.5, NULL, false, NULL",
         num == -7 and f == 1.5 and s == nil and b == false and z == nil,
         table.concat({ tostring(num), tostring(f), tostring(s), tostring(b), tostring(z) }, ", "))
   cpv:close()
end
conn:setoption("numbers", "float")
drop("lt_oci8_pv")

local s9 = assert(conn:prepare("select nvl2(:1, 'value', 'null') from dual"))
ok1, a1 = run(s9, { 7 })
check("execute{7} binds the number 7", ok1 and a1 == "value", tostring(a1))
ok1, a1 = run(s9, { T.null })
check("execute{T.null} binds NULL", ok1 and a1 == "null", tostring(a1))
ok1, a1 = run(s9, nil)
check("execute(nil) binds NULL", ok1 and a1 == "null", tostring(a1))
ok1, a1 = run(s9, { { T.null, T.int } })
check("{T.null, T.int} is NULL", ok1 and a1 == "null", tostring(a1))
ok1, a1 = run(s9, { { "x", T.null } })
check("{value, T.null} is NULL", ok1 and a1 == "null", tostring(a1))
s9:close()

local s10 = assert(conn:prepare("select cast(:1 as number) from dual"))
ok1, a1 = run(s10, { { 3.0, T.int } })
check("{3.0, T.int} binds 3", ok1 and tonumber(a1) == 3, tostring(a1))
r7, e7 = pcall(s10.execute, s10, { { 3.7, T.int } })
check("{3.7, T.int} raises an error",
      not r7 and tostring(e7):find("does not match", 1, true) ~= nil, tostring(e7))
for _, bad in ipairs{ { "a function", print }, { "a thread", coroutine.create(print) },
                      { "a userdata", io.stdout }, { "a table that is not a pair", { 1, 2, 3 } } } do
   r7, e7 = pcall(s10.execute, s10, bad[2], 1)
   check("variable argument: " .. bad[1] .. " raises an error",
         not r7 and tostring(e7):find("LuaSQL:", 1, true) ~= nil, tostring(e7))
end
ok1, a1 = run(s10)
check("bindings kept after the errors", ok1 and tonumber(a1) == 3, tostring(a1))
s10:close()

local s11 = assert(conn:prepare("select to_char(:1, 'YYYY-MM-DD') from dual"))
ok1, a1 = run(s11, { { "2026-11-07", T.date } })
check("single typed value in a table", ok1 and a1 == "2026-11-07", tostring(a1))
ok1, e1 = run(s11, { "2026-11-07", T.date })
check("a pair alone is a table of two parameters: ORA-01036",
      not ok1 and tostring(e1):find("ORA%-01036") ~= nil, tostring(e1))
s11:close()

print("-- T.binary")
local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
bytes = table.concat(bytes)          -- "\0" and bytes above 0x7F
local big = string.rep(bytes, 400)   -- 102400 bytes, bound as SQLT_LBI
drop("lt_oci8_bin")
exec("CREATE TABLE lt_oci8_bin (id NUMBER, r RAW(2000), b BLOB)")
local sb = assert(conn:prepare("INSERT INTO lt_oci8_bin VALUES (:1, :2, :3)"))
rpv, epv = sb:execute(1, { bytes, T.binary }, { bytes, T.binary })
check("binary into RAW and BLOB", rpv == 1, epv)
rpv, epv = sb:execute(2, { T.null, T.binary }, { big, T.binary })
check("NULL with type, 102400 bytes into BLOB", rpv == 1, epv)
sb:close()
do
   local cbin = assert(exec("SELECT r, b FROM lt_oci8_bin ORDER BY id"))
   local raw, blob = cbin:fetch()
   check("RAW: length and content", raw == bytes, raw and #raw)
   check("BLOB: length and content", blob == bytes, blob and #blob)
   raw, blob = cbin:fetch()
   check("RAW NULL", raw == nil, raw and #raw)
   check("BLOB of 102400 bytes", blob == big, blob and #blob)
   cbin:close()
end
local mb = string.rep(bytes, 4096)   -- 1 MiB
rpv, epv = conn:execute("INSERT INTO lt_oci8_bin (id, b) VALUES (3, :1)", { { mb, T.binary } })
check("1 MiB into BLOB", rpv == 1, epv)
check("1 MiB read back", scalar("SELECT b FROM lt_oci8_bin WHERE id = 3") == mb)
rpv, epv = conn:execute("DECLARE x BLOB := :1; BEGIN NULL; END;",
                        { { bytes:rep(128), T.binary } })
check("PL/SQL with 32768 bytes: nil, msg with ORA-01460",
      rpv == nil and tostring(epv):find("ORA%-01460") ~= nil, tostring(epv))
rpv, epv = conn:execute("DECLARE x BLOB := :1; BEGIN NULL; END;",
                        { { bytes:rep(128):sub(2), T.binary } })
check("PL/SQL with 32767 bytes", rpv ~= nil, epv)
drop("lt_oci8_bin")

print("-- variable arguments and the number of placeholders")
local s12 = assert(conn:prepare("select cast(:1 as number), cast(:2 as number) from dual"))
ok1, a1, b1 = run(s12, 1, 2)
check("two variable arguments", ok1 and tonumber(a1) == 1 and tonumber(b1) == 2,
      tostring(a1) .. ", " .. tostring(b1))
ok1, e1 = run(s12, 5)
check("execute(1, 2), then execute(5): nil, msg",
      not ok1 and tostring(e1):find("statement has 2 parameters, 1 given", 1, true) ~= nil,
      tostring(e1))
ok1, e1 = run(s12, 1, 2, 3)
check("three for two: nil, msg",
      not ok1 and tostring(e1):find("3 given", 1, true) ~= nil, tostring(e1))
ok1, a1, b1 = run(s12)
check("bindings kept after a wrong number", ok1 and tonumber(a1) == 1 and tonumber(b1) == 2,
      tostring(a1) .. ", " .. tostring(b1))
s12:close()

local s13 = assert(conn:prepare("SELECT :a + :a FROM dual"))
ok1, a1 = run(s13, { a = 5 })
check("SELECT :a + :a by name: one value", ok1 and tonumber(a1) == 10, tostring(a1))
ok1, a1 = run(s13, 5, 7)
check("SELECT :a + :a as variable arguments: two values", ok1 and tonumber(a1) == 12,
      tostring(a1))
ok1, e1 = run(s13, 5)
check("SELECT :a + :a with one variable argument: nil, msg",
      not ok1 and tostring(e1):find("statement has 2 parameters", 1, true) ~= nil,
      tostring(e1))
s13:close()

local s14 = assert(conn:prepare("DECLARE x NUMBER; BEGIN x := :a + :a; END;"))
rpv, epv = s14:execute(5)
check("PL/SQL with a repeated name: one variable argument", rpv ~= nil, epv)
rpv, epv = s14:execute(5, 7)
check("PL/SQL with a repeated name: two give nil, msg",
      rpv == nil and tostring(epv):find("statement has 1 parameter, 2 given", 1, true) ~= nil,
      tostring(epv))
s14:close()

print("-- conn:execute with parameters")
do
   local function first_row(...)
      local c, ce = conn:execute(...)
      if type(c) ~= "userdata" then return nil, ce end
      local val = c:fetch()
      c:close()
      return val
   end
   a1, e1 = first_row("select cast(:1 as number) from dual", 41)
   check("variable arguments", tonumber(a1) == 41, e1 or tostring(a1))
   a1, e1 = first_row("select cast(:id as number) from dual", { id = 42 })
   check("table by name", tonumber(a1) == 42, e1 or tostring(a1))
   a1, e1 = first_row("select :1 || :2 from dual", { "a", "b" })
   check("table by position", a1 == "ab", e1 or tostring(a1))
   a1, e1 = first_row("select :1 + :2 from dual", 1)
   check("wrong number: nil, msg",
         a1 == nil and tostring(e1):find("statement has 2 parameters, 1 given", 1, true) ~= nil,
         tostring(e1))
   a1, e1 = first_row("select :1 + :2 from dual", { 1 })
   check("table without a value for :2: ORA-01008",
         a1 == nil and tostring(e1):find("ORA%-01008") ~= nil, tostring(e1))
   a1, e1 = first_row("select :x from dual", { y = 1 })
   check("unknown name: ORA-01036",
         a1 == nil and tostring(e1):find("ORA%-01036") ~= nil, tostring(e1))
   -- the cursor keeps the parameters until it is closed
   local c, ce = conn:execute("select :1, :2 from dual connect by level <= 3",
                              { "2026-11-07 12:00:00.25", T.timestamp },
                              string.rep("y", 100))
   check("query with parameters", type(c) == "userdata", ce)
   if type(c) == "userdata" then
      for _ = 1, 3 do collectgarbage("collect") end
      local t, s = c:fetch()
      check("parameters kept by the cursor",
            t == "2026-11-07 12:00:00.250000" and s == string.rep("y", 100), tostring(t))
      c:close()
   end
   drop("lt_oci8_ce")
   exec("CREATE TABLE lt_oci8_ce (id NUMBER, s VARCHAR2(10))")
   rpv, epv = conn:execute("INSERT INTO lt_oci8_ce VALUES (:1, :2)", 1, "x")
   check("DML with variable arguments", rpv == 1, epv)
   rpv, epv = conn:execute("INSERT INTO lt_oci8_ce VALUES (:id, :s)", { id = 2, s = T.null })
   check("DML with a table", rpv == 1, epv)
   check("two rows", tonumber(scalar("SELECT COUNT(*) FROM lt_oci8_ce")) == 2)
   drop("lt_oci8_ce")
   r7, e7 = pcall(conn.execute, conn, "select 1 from dual", print)
   check("invalid parameter raises an error",
         not r7 and tostring(e7):find("cannot be bound", 1, true) ~= nil, tostring(e7))
   a1, e1 = first_row("select 7 from dual")
   check("without parameters as before", tonumber(a1) == 7, e1 or tostring(a1))
end

print("-- TIMESTAMP WITH LOCAL TIME ZONE follows the session time zone")
local ltz_instants = { "2026-07-19 13:45:30 Europe/Berlin", "2026-12-19 13:45:30 Europe/Berlin" }
for _, zone in ipairs({ "+00:00", "+05:30", "-03:00", "Europe/Berlin" }) do
   exec("ALTER SESSION SET TIME_ZONE = '" .. zone .. "'")
   for _, instant in ipairs(ltz_instants) do
      local lexpr = "CAST(TIMESTAMP '" .. instant .. "' AS TIMESTAMP WITH LOCAL TIME ZONE)"
      local cz, ez = conn:execute("select " .. lexpr .. ", to_char(" .. lexpr ..
				  ", 'YYYY-MM-DD HH24:MI:SS.FF6') from dual")
      local drv, srv
      if cz then drv, srv = cz:fetch(); cz:close() end
      check("LTZ in session zone " .. zone .. ": " .. instant:sub(1, 10),
	    drv ~= nil and drv == srv, ez or (tostring(drv) .. " vs " .. tostring(srv)))
   end
end
-- TIMESTAMP WITH TIME ZONE keeps the zone of the value
exec("ALTER SESSION SET TIME_ZONE = '+05:30'")
ok, v, e = fetch1("select to_timestamp_tz('2026-07-19 13:45:30 +02:00', 'YYYY-MM-DD HH24:MI:SS TZH:TZM') from dual")
check("TZ value keeps its own zone", ok and v == "2026-07-19 13:45:30.000000 +02:00", e or tostring(v))
exec("ALTER SESSION SET TIME_ZONE = LOCAL")

print("-- OCI_SUCCESS_WITH_INFO is a success")
local aggr = "select sum(x) from (select null x from dual union all select 1 from dual)"
ok, v, e = fetch1(aggr)
check("aggregate with NULL (ORA-24347) gives its row", ok and tonumber(v) == 1, e or tostring(v))
local sa = assert(conn:prepare(aggr))
local ca, ea = sa:execute()
local va = ca and ca:fetch()
if ca then ca:close() end
check("the same over a prepared statement", tonumber(va) == 1, ea or tostring(va))
sa:close()
local bad = "CREATE OR REPLACE PROCEDURE lt_oci8_warn IS BEGIN x; END;"
local rw, ew = conn:execute(bad)
check("compilation error (ORA-24344) is a success", rw == 0, ew or tostring(rw))
local sw = assert(conn:prepare(bad))
rw, ew = sw:execute()
check("the same over a prepared statement", rw == 0, ew or tostring(rw))
sw:close()
ok, v, e = fetch1("select status from user_objects where object_name = 'LT_OCI8_WARN'")
check("procedure exists and is INVALID", ok and v == "INVALID", e or tostring(v))
pcall(exec, "DROP PROCEDURE lt_oci8_warn")

print("-- cleanup")
r, e = drop(TABLE)
check("drop table", r ~= nil, e)
check("close connection", conn:close())
check("close environment", env:close())

if failed > 0 then
   print(string.format("\n%d check(s) FAILED.", failed))
   os.exit(1)
end
print("\nDone, all checks passed.")
