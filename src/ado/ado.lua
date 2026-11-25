---------------------------------------------------------------------
-- ADO driver implemented using LuaCOM
---------------------------------------------------------------------

local luacom = require"luacom"

-- the driver reads values with luacom.SetConversion (OneLuaPro/luacom)
if type(luacom) ~= "table" or type(luacom.SetConversion) ~= "function" then
    error("LuaSQL: luasql.ado needs luacom with SetConversion"..
          " (OneLuaPro/luacom ca4d26a or later)", 0)
end

---------------------------------------------------------------------
-- luasql table name
---------------------------------------------------------------------
local luasql = {}

local ADOTypes = {}

local adoVersion

do
    local conn = luacom.CreateObject("ADODB.Connection")
    if not conn then
        error("LuaSQL: cannot create an ADODB.Connection object", 0)
    end
    local typeinfo = luacom.GetTypeInfo(conn)
    local typelib = typeinfo:GetTypeLib()
    local enums = typelib:ExportEnumerations()
    for k, v in pairs(enums.DataTypeEnum) do
        ADOTypes[k] = v
        ADOTypes[v] = k
    end
    adoVersion = conn.Version
end

-- constants of ADO
local adStateOpen = 1
local adCmdText = 1
-- adXactCommitRetaining + adXactAbortRetaining
local adXactRetaining = 131072 + 262144

-- one metatable per object, so that __tostring can report the state of
-- that object
local function newmeta(kind, is_closed, gc)
  return {
    __metatable = "LuaSQL: you're not allowed to get this metatable",
    __close = function(obj) obj:close() end,
    __gc = gc,
    __tostring = function(obj)
      if is_closed() then
        return "ADO " .. kind .. " (closed)"
      end
      return string.format("ADO %s (%p)", kind, obj)
    end,
  }
end

luasql._COPYRIGHT = "Copyright (C) 2003-2006 Kepler Project"
luasql._DESCRIPTION = "LuaSQL is a simple interface from Lua to a DBMS"
luasql._VERSION = "LuaSQL 2.8.1"
-- the version of ADO, in the form ADO gives it (e.g. "10.0")
luasql._CLIENTVERSION = adoVersion ~= nil and tostring(adoVersion) or nil

---------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------
-- an API error: raised without a position, as the drivers written in C
local function apierror(msg)
    error("LuaSQL: " .. msg, 0)
end

-- every function that calls COM checks this first: with abort_on_error
-- false a failing COM call returns nothing instead of raising, and the
-- driver would take it as a success
local function checkluacom()
    if not luacom.config.abort_on_error then
        apierror("luasql.ado needs luacom.config.abort_on_error = true")
    end
end

-- strip luacom's "COM exception:(file,line):" prefix and the line ends
-- at the end; an error of a property (e.g. Field.Value) also carries the
-- position of the Lua code that read it ("...ado.lua:123: ")
local function clean(msg)
    msg = tostring(msg)
    local pos = msg:find("COM exception:(", 1, true)
    if pos and (pos == 1 or msg:sub(1, pos - 1):find("^[^\n]*:%d+: $")) then
        msg = msg:sub(pos):gsub("^COM exception:%b():%s*", "")
    end
    return (msg:gsub("[\r\n%s]+$", ""))
end

-- the message of a failed call on a connection: the error records of
-- conn.Errors (Number ~= 0, notices are dropped), joined by one line
-- end. They are used only if one of them is the error luacom reports,
-- so that a record left by an earlier call is never taken for this one;
-- otherwise (ADO's own errors have no record) luacom's text.
local function failmessage(conObj, err)
    local text = clean(err)
    if not conObj then return text end
    local ok, msgs, found = pcall(function()
        local errors = conObj.Errors
        local list, seen = {}, false
        for i = 0, errors.Count - 1 do
            local rec = errors:Item(i)
            if rec.Number ~= 0 then
                local desc = clean(rec.Description or "")
                list[#list + 1] = desc
                if desc == text then seen = true end
            end
        end
        return list, seen
    end)
    if ok and found then
        return table.concat(msgs, "\n")
    end
    return text
end

-- conversion of the values of a field, by Field.Type
local conversion = {
    [ADOTypes.adBigInt or 20] = { DecimalFormat = "exact" },
    [ADOTypes.adUnsignedBigInt or 21] = { DecimalFormat = "exact" },
    [ADOTypes.adNumeric or 131] = { DecimalFormat = "string" },
    [ADOTypes.adDecimal or 14] = { DecimalFormat = "string" },
    [ADOTypes.adVarNumeric or 139] = { DecimalFormat = "string" },
    [ADOTypes.adCurrency or 6] = { DecimalFormat = "string" },
    [ADOTypes.adDate or 7] = { DateFormat = "iso" },
    [ADOTypes.adDBDate or 133] = { DateFormat = "iso" },
    [ADOTypes.adDBTime or 134] = { DateFormat = "iso" },
    [ADOTypes.adDBTimeStamp or 135] = { DateFormat = "iso" },
}

-- what luacom gives, made into the value of luasql (by Field.Type);
-- luacom's ISO text is "YYYY-MM-DD HH:MM:SS.mmm"
local postprocess = {
    -- VT_R8 from MSDASQL
    [ADOTypes.adUnsignedInt or 19] = function(v)
        return math.tointeger(v) or v
    end,
    [ADOTypes.adDBDate or 133] = function(v)
        return type(v) == "string" and v:sub(1, 10) or v
    end,
    -- ADO gives no fraction of a second and the current date
    [ADOTypes.adDBTime or 134] = function(v)
        return type(v) == "string" and v:sub(12, 19) or v
    end,
}

---------------------------------------------------------------------
-- function that returns an ADO environment
---------------------------------------------------------------------
local createConnection, createCursor

function luasql.ado()
    checkluacom()
    local isClosed  = false
    local nconns    = 0

    local env = {}

    setmetatable(env, newmeta("environment", function() return isClosed end))

    env.ADOTypes = ADOTypes

    -- called once by every connection when it is closed or collected
    local function connClosed()
        nconns = nconns - 1
    end

    function env:close()
        if self ~= env then apierror("environment expected") end

        if isClosed then
            return false, "Environment is already closed"
        end
        if nconns ~= 0 then
            return false, "There are open connections"
        end

        isClosed = true

        return true
    end

    function env:connect(sourcestr, user, pass, opts)
        if self ~= env then apierror("environment expected") end

        if isClosed then
            apierror("environment is closed")
        end
        checkluacom()

        if type(sourcestr) ~= "string" then
            apierror("data source must be a string")
        end
        if user ~= nil and type(user) ~= "string" then
            apierror("user name must be a string")
        end
        if pass ~= nil and type(pass) ~= "string" then
            apierror("password must be a string")
        end
        if type(opts) ~= "number" then opts = -1 end  -- adConnectUnspecified

        local ok, conn = pcall(luacom.CreateObject, "ADODB.Connection")
        if not ok or not conn then
            return nil, "LuaSQL: cannot create an ADODB.Connection object"
        end
        local errmsg
        ok, errmsg = pcall(conn.Open, conn, sourcestr, user or "", pass or "",
                           opts)
        if not ok then
            return nil, failmessage(conn, errmsg)
        end

        if conn.State ~= adStateOpen then
            return nil, "LuaSQL: the connection is not open"
        end

        nconns = nconns + 1

        return createConnection(conn, env, connClosed)
    end

    return env
end


---------------------------------------------------------------------
-- creates an ADO connection
---------------------------------------------------------------------
function createConnection(conObj, env, closeFunc)

    local ncursors = 0
    local isClosed = false
    local autocommit = true   -- ADO's own mode: no BeginTrans

    local con = {}

    local function setattributes(value)
        conObj.Attributes = value
    end

    -- ends the connection: an open transaction is rolled back first (ADO
    -- refuses Close during a transaction). Failures are ignored (B1b): if
    -- Close still fails (e.g. after a lost connection), the COM object is
    -- left to the garbage collector, which releases it.
    local function shutdown()
        isClosed = true
        if not autocommit then
            pcall(setattributes, 0)
            pcall(conObj.RollbackTrans, conObj)
        end
        pcall(conObj.Close, conObj)
        conObj = nil
        closeFunc()
        env = nil -- luacheck: ignore (kept the environment until now)
    end

    -- the garbage collector closes a connection only without open
    -- cursors (they keep it, so this is the normal case)
    local function gc()
        if not isClosed and ncursors == 0 then
            shutdown()
        end
    end

    setmetatable(con, newmeta("connection", function() return isClosed end,
                              gc))

    local function check(self)
        if self ~= con then apierror("connection expected") end
        if isClosed then apierror("connection is closed") end
        checkluacom()
    end

    -- called once by every cursor when it is closed or collected
    local function cursorClosed()
        ncursors = ncursors - 1
    end

    local function fail(err)
        return failmessage(conObj, err)
    end

    function con:close()
        if self ~= con then apierror("connection expected") end

        if isClosed then
            return false, "Connection is already closed"
        end
        if ncursors ~= 0 then
            return false, "There are open cursors"
        end

        shutdown()

        return true
    end

    function con:commit()
        check(self)

        if autocommit then
            return true
        end

        -- with adXactCommitRetaining ADO begins the next transaction
        local cond, err = pcall(conObj.CommitTrans, conObj)
        if not cond then
            return false, fail(err)
        end

        return true
    end

    function con:execute(sql)
        check(self)

        if type(sql) ~= "string" then
            apierror("SQL must be a string, got " .. type(sql))
        end

        local cond, res, upcount = pcall(conObj.Execute, conObj, sql, nil,
                                         adCmdText)
        if not cond then
            return nil, fail(res)
        end

        local open
        cond, open = pcall(function()
            return res ~= nil and res.State == adStateOpen
        end)
        if not cond then
            return nil, fail(open)
        end

        if open then
            local cur, err = createCursor(res, con, cursorClosed, fail)
            if not cur then
                return nil, err
            end
            ncursors = ncursors + 1
            return cur
        end

        if not upcount then upcount = 0 end
        return math.tointeger(upcount) or upcount
    end

    function con:rollback()
        check(self)

        if autocommit then
            return true
        end

        -- with adXactAbortRetaining ADO begins the next transaction
        local cond, err = pcall(conObj.RollbackTrans, conObj)
        if not cond then
            return false, fail(err)
        end

        return true
    end

    function con:setautocommit(bool)
        check(self)

        bool = not not bool
        if bool == autocommit then
            return true
        end

        if bool then
            -- end the transaction without beginning the next one
            local cond, err = pcall(setattributes, 0)
            if cond then
                cond, err = pcall(conObj.RollbackTrans, conObj)
            end
            if not cond then
                pcall(setattributes, adXactRetaining)
                return false, fail(err)
            end
        else
            local cond, err = pcall(setattributes, adXactRetaining)
            if cond then
                cond, err = pcall(conObj.BeginTrans, conObj)
            end
            if not cond then
                pcall(setattributes, 0)
                return false, fail(err)
            end
        end

        autocommit = bool

        return true
    end

    return con
end

---------------------------------------------------------------------
-- creates an ADO cursor (recordset)
---------------------------------------------------------------------
function createCursor(rs, con, closeFunc, fail)

    local isClosed = false
    local fields = {}      -- the Field objects, read once
    local post = {}        -- conversions in Lua, by Field.Type
    local col_names = {}
    local col_types = {}
    local ncols
    local values = {}
    local started = false  -- the first row needs no MoveNext

    -- the Field objects and their conversion, once per cursor
    local cond, err = pcall(function()
        local flds = rs.Fields
        ncols = flds.Count
        for i = 1, ncols do
            local field = flds:Item(i - 1)
            local ty = field.Type
            local settings = conversion[ty]
            if settings then
                luacom.SetConversion(field, settings)
            end
            fields[i] = field
            post[i] = postprocess[ty] or false
            col_names[i] = field.Name
            col_types[i] = ADOTypes[ty] or tostring(ty)
        end
        -- CacheSize stays 1: with more rows in the cache MSDASQL delivers
        -- long columns (e.g. bytea) and all columns after them as NULL
    end)
    if not cond then
        local msg = fail(err)
        pcall(rs.Close, rs)
        return nil, msg
    end

    local res = {}

    local function shutdown()
        isClosed = true
        pcall(rs.Close, rs)
        rs = nil
        fields = nil
        closeFunc()
        con = nil -- luacheck: ignore (kept the connection until now)
    end

    local function gc()
        if not isClosed then
            shutdown()
        end
    end

    setmetatable(res, newmeta("cursor", function() return isClosed end, gc))

    local function check(self)
        if self ~= res then apierror("cursor expected") end
        if isClosed then apierror("cursor is closed") end
    end

    -- moves to the next row and reads it; false at the end
    local function step()
        if started then
            rs:MoveNext()
        end
        started = true
        if rs.EOF then
            return false
        end
        for i = 1, ncols do
            values[i] = fields[i].Value
        end
        return true
    end

    function res:close()
        if self ~= res then apierror("cursor expected") end

        if isClosed then
            return false, "Cursor is already closed"
        end

        shutdown()

        return true
    end

    function res:fetch(tb, modestring)
        check(self)
        checkluacom()

        local ok, more = pcall(step)
        if not ok then
            return nil, fail(more)
        end
        if not more then
            shutdown()
            return nil
        end

        for i = 1, ncols do
            local f = post[i]
            if f and values[i] ~= nil then
                values[i] = f(values[i])
            end
        end

        local arg_tb = tb

        if tb == nil or type(tb) ~= "table" then
            tb = {}
        end

        if modestring == nil or type(modestring) ~= "string" then
            modestring = "n"
        end

        local numbered = modestring:find("n", 1, true) ~= nil
        local named = modestring:find("a", 1, true) ~= nil

        if modestring == "n" and not arg_tb then
            return table.unpack(values, 1, ncols)
        end
        for i = 1, ncols do
            if numbered then
                tb[i] = values[i]
            end
            if named then
                tb[col_names[i]] = values[i]
            end
        end
        return tb
    end

    function res:getcolnames()
        check(self)

        return col_names
    end

    function res:getcoltypes()
        check(self)

        return col_types
    end

    return res
end

return luasql
