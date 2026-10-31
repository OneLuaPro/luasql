--- Transactions with luasql.oci8: autocommit, commit and rollback, and
-- what happens to an open transaction when a connection is closed.
--
-- Set ORACLE_SOURCE, ORACLE_USER and ORACLE_PASSWORD before running it.

local driver = require "luasql.oci8"

local source = os.getenv("ORACLE_SOURCE") or "localhost:1521/FREEPDB1"
local user = os.getenv("ORACLE_USER") or "scott"
local password = assert(os.getenv("ORACLE_PASSWORD"), "set ORACLE_PASSWORD")

local env = assert(driver.oci8())
local conn = assert(env:connect(source, user, password))
assert(conn:setoption("numbers", "exact"))

local function count(c)
  local cur = assert(c:execute("SELECT COUNT(*) FROM luasql_ex_account"))
  local n = cur:fetch()
  cur:close()
  return n
end

-- DDL commits implicitly, so create the table before the transaction
assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_account PURGE"))
assert(conn:execute(
  "CREATE TABLE luasql_ex_account (id NUMBER PRIMARY KEY, balance NUMBER)"))

-- a new connection commits every statement (autocommit)
assert(conn:execute("INSERT INTO luasql_ex_account VALUES (1, 100)"))

-- with autocommit off, changes wait for commit or rollback
assert(conn:setautocommit(false))
assert(conn:execute("INSERT INTO luasql_ex_account VALUES (2, 50)"))
assert(conn:rollback())
print(count(conn))   --> 1

assert(conn:execute("UPDATE luasql_ex_account SET balance = balance - 30 WHERE id = 1"))
assert(conn:execute("INSERT INTO luasql_ex_account VALUES (2, 30)"))
assert(conn:commit())
print(count(conn))   --> 2

-- a failing statement rolls back only itself
assert(conn:execute("INSERT INTO luasql_ex_account VALUES (3, 10)"))
print(conn:execute("INSERT INTO luasql_ex_account VALUES (3, 10)"))
--> nil   LuaSQL: ORA-00001: unique constraint ... violated
assert(conn:commit())
print(count(conn))   --> 3

-- closing a connection rolls back its open transaction
local other = assert(env:connect(source, user, password))
assert(other:setautocommit(false))
assert(other:execute("DELETE FROM luasql_ex_account"))
assert(other:close())   -- not committed: the rows stay
print(count(conn))   --> 3

assert(conn:setautocommit(true))
assert(conn:execute("DROP TABLE luasql_ex_account PURGE"))
assert(conn:close())
assert(env:close())
