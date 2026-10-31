--- Large objects and JSON with luasql.oci8: CLOB and BLOB of any size are
-- plain Lua strings, JSON arrives as text.
--
-- Set ORACLE_SOURCE, ORACLE_USER and ORACLE_PASSWORD before running it.
-- The JSON part needs Oracle 21c or later and uses lua-cjson if present.

local driver = require "luasql.oci8"
local T = driver.type

local source = os.getenv("ORACLE_SOURCE") or "localhost:1521/FREEPDB1"
local user = os.getenv("ORACLE_USER") or "scott"
local password = assert(os.getenv("ORACLE_PASSWORD"), "set ORACLE_PASSWORD")

local env = assert(driver.oci8())
local conn = assert(env:connect(source, user, password))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_doc PURGE"))
assert(conn:execute(
  "CREATE TABLE luasql_ex_doc (id NUMBER PRIMARY KEY, txt CLOB, bin BLOB, meta JSON)"))

-- write: a string parameter fills a CLOB of any length; a BLOB is filled
-- from SQL here, e.g. with HEXTORAW
local text = string.rep("Grüße aus Lua! ", 20000)   -- 300000 characters
local ins = assert(conn:prepare(
  "INSERT INTO luasql_ex_doc VALUES (:1, :2, TO_BLOB(HEXTORAW(:3)), :4)"))
assert(ins:execute{ { 1, T.int }, { text, T.string }, { "00FF7F", T.string },
                    { '{"title":"Gruß","pages":[1,2,3]}', T.string } })
ins:close()

-- read: CLOB and BLOB arrive as strings, completely
local cur = assert(conn:execute("SELECT txt, bin, meta FROM luasql_ex_doc"))
print(table.concat(cur:getcoltypes(), ", "))   --> string, binary, json
local txt, bin, meta = cur:fetch()
cur:close()
print(#txt == #text, txt == text)   --> true   true
print(#bin, bin:byte(1, -1))        --> 3   0   255   127
print(meta)                         --> {"title":"Gruß","pages":[1,2,3]}

-- decode JSON with a JSON module, e.g. lua-cjson
local ok, cjson = pcall(require, "cjson")
if ok then
  local doc = cjson.decode(meta)
  print(doc.title, #doc.pages)      --> Gruß   3
end

assert(conn:execute("DROP TABLE luasql_ex_doc PURGE"))
assert(conn:close())
assert(env:close())
